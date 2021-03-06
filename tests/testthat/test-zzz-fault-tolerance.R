context("fault tolerance")

test_that("heartbeat", {
  skip_if_not_installed("heartbeatr")
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  res <- obj$worker_config_save("localhost", heartbeat_period = 3,
                                copy_redis = TRUE)
  expect_equal(res$heartbeat_period, 3)

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  dat <- obj$worker_info(wid)[[1]]
  expect_equal(dat$heartbeat_key,
               rrq_key_worker_heartbeat(context$id, wid))
  expect_equal(obj$con$EXISTS(dat$heartbeat_key), 1)
  expect_lte(obj$con$PTTL(dat$heartbeat_key),
             res$heartbeat_period * 3 * 1000)
  ## This might be just a bit too strict over slow connections if the
  ## worker is not close to the connection, so I've subtracted .1s off
  ## arbitrarily
  expect_gte(obj$con$PTTL(dat$heartbeat_key),
             res$heartbeat_period * 2 * 1000 - 100)

  res <- obj$worker_stop(wid, timeout = 1)
  expect_equal(obj$con$EXISTS(dat$heartbeat_key), 0)
  expect_equal(obj$worker_list(), character(0))
})

test_that("interrupt stuck worker (local)", {
  skip_if_not_installed("heartbeatr")
  ## This one tests that if a worker is stuck on a long running task
  ## that we can shunt them off it.  It will not work on windows
  ## because there is no concept of interrupt that we can easily use.
  skip_on_os("windows")

  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))

  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  ## We need to set time_poll to be fairly fast because BLPOP is not
  ## interruptable; the interrupt will only be handled _after_ R gets
  ## control back.
  res <- obj$worker_config_save("localhost", time_poll = 1,
                                copy_redis = TRUE)

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)
  pid <- obj$worker_info()[[wid]]$pid

  expect_equal(obj$message_send_and_wait("PING"),
               setNames(list("PONG"), wid))

  t <- obj$enqueue(slowdouble(10000))
  wait_status(t, obj, status = TASK_PENDING)
  expect_equal(obj$task_status(t), setNames(TASK_RUNNING, t))
  expect_equal(obj$worker_status(wid), setNames(WORKER_BUSY, wid))

  tools::pskill(pid, tools::SIGINT)
  wait_status(t, obj, status = TASK_RUNNING)

  expect_equal(obj$task_status(t), setNames(TASK_INTERRUPTED, t))
  expect_equal(obj$worker_status(wid), setNames(WORKER_IDLE, wid))

  expect_equal(obj$message_send_and_wait("PING"),
               setNames(list("PONG"), wid))

  ## Then try the interrupt _during_ a string of messages and be sure
  ## that the messages get requeued correctly.
  tools::pskill(pid, tools::SIGINT)
  expect_equal(obj$message_send_and_wait("PING"),
               setNames(list("PONG"), wid))

  tmp <- obj$worker_log_tail(wid, 3L)
  expect_equal(tmp$command,
               c("REQUEUE", "MESSAGE", "RESPONSE"))
})

test_that("interrupt stuck worker (via heartbeat)", {
  skip_if_not_installed("heartbeatr")
  ## Basically the same test as above, but we'll do it via the
  ## heartbeat thread.  These might be worth merging.
  skip_on_os("windows")

  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))

  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  ## We need to set time_poll to be fairly fast because BLPOP is not
  ## interruptable; the interrupt will only be handled _after_ R gets
  ## control back.
  res <- obj$worker_config_save("localhost", time_poll = 1,
                                heartbeat_period = 3,
                                copy_redis = TRUE)

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  expect_equal(obj$message_send_and_wait("PING"),
               setNames(list("PONG"), wid))

  t <- obj$enqueue(slowdouble(10000))
  wait_status(t, obj, status = TASK_PENDING)
  expect_equal(obj$task_status(t), setNames(TASK_RUNNING, t))
  expect_equal(obj$worker_status(wid), setNames(WORKER_BUSY, wid))

  worker_send_signal(obj$con, obj$keys, tools::SIGINT, wid)
  wait_status(t, obj, status = TASK_RUNNING)

  expect_equal(obj$task_status(t), setNames(TASK_INTERRUPTED, t))
  expect_equal(obj$worker_status(wid), setNames(WORKER_IDLE, wid))

  expect_equal(obj$message_send_and_wait("PING"),
               setNames(list("PONG"), wid))

  ## Then try the interrupt _during_ a string of messages and be sure
  ## that the messages get requeued correctly.
  worker_send_signal(obj$con, obj$keys, tools::SIGINT, wid)
  expect_equal(obj$message_send_and_wait("PING"),
               setNames(list("PONG"), wid))

  tmp <- obj$worker_log_tail(wid, 3L)
  expect_equal(tmp$command,
               c("REQUEUE", "MESSAGE", "RESPONSE"))
})

test_that("detect killed worker (via heartbeat)", {
  skip_if_not_installed("heartbeatr")
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))

  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  ## We need to set time_poll to be fairly fast because BLPOP is not
  ## interruptable; the interrupt will only be handled _after_ R gets
  ## control back.
  res <- obj$worker_config_save("localhost", time_poll = 1,
                                heartbeat_period = 1,
                                copy_redis = TRUE)

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)
  pid <- obj$worker_info()[[wid]]$pid

  key <- rrq_key_worker_heartbeat(context$id, wid)
  expect_equal(obj$con$EXISTS(key), 1)
  expire <- res$heartbeat_period * 3
  expect_equal(obj$con$GET(key), as.character(expire))
  expect_lte(obj$con$TTL(key), expire)

  t <- obj$enqueue(slowdouble(10000))
  wait_status(t, obj, status = TASK_PENDING)
  expect_equal(obj$task_status(t), setNames(TASK_RUNNING, t))
  expect_equal(obj$worker_status(wid), setNames(WORKER_BUSY, wid))

  tools::pskill(pid, tools::SIGTERM)
  Sys.sleep(0.1)
  expect_equal(obj$task_status(t), setNames(TASK_RUNNING, t))
  expect_equal(obj$worker_status(wid), setNames(WORKER_BUSY, wid))

  ## This is a bit annoying as it takes a while to run through;
  Sys.sleep(expire)

  ## Our key has gone!  Marvellous!
  expect_equal(obj$con$EXISTS(key), 0)

  expect_equal(obj$worker_list(), wid)
  dat1 <- heartbeat_time_remaining(obj)
  dat2 <- identify_orphan_tasks(obj)
  expect_equal(obj$worker_list(), character(0))
  dat3 <- heartbeat_time_remaining(obj)

  cmp <- data.frame(worker_id = wid, time = -2, status = WORKER_BUSY,
                    task_id = t, stringsAsFactors = FALSE)
  expect_equal(dat1, cmp)
  expect_equal(dat2, cmp[c("worker_id", "task_id")])
  expect_equal(dat3, cmp[integer(0), ])

  expect_message(cleanup_orphans(obj, dat1), "Lost 1 worker:")
  expect_message(cleanup_orphans(obj, dat1), "Orphaning 1 task:")
})
