context("rrq")

test_that("empty", {
  root <- tempfile()
  context <- context::context_save(root)
  context <- context::context_load(context, new.env(parent = .GlobalEnv))

  obj <- rrq_controller(context, redux::hiredis())
  expect_is(obj, "rrq_controller")

  expect_equal(obj$worker_list(), character(0))
  expect_equal(obj$task_list(), character(0))
  expect_equal(obj$queue_length(), 0)
  expect_equal(obj$queue_list(), character(0))

  id <- obj$enqueue(sin(1))
  expect_equal(obj$task_list(), id)
  expect_equal(obj$queue_list(), id)
  expect_equal(obj$task_status(id), setNames(TASK_PENDING, id))

  expect_true(
    file.exists(file.path(obj$context$root$path, "bin", "rrq_worker")))

  test_queue_clean(context$id)
})

test_that("basic use", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  ## For testing, use: worker_command(obj)
  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  t <- obj$enqueue(slowdouble(0.1))
  expect_is(t, "character")
  expect_equal(obj$task_wait(t, 2, progress = PROGRESS), 0.2)
  expect_equal(obj$task_result(t), 0.2)

  t <- obj$enqueue(getwd())
  expect_equal(obj$task_wait(t, 2, progress = PROGRESS), getwd())
})

test_that("worker working directory", {
  other <- tempfile()
  dir.create(other, FALSE, TRUE)
  file.copy("myfuns.R", other)

  with_wd(other, {
    root <- "context"
    context <- context::context_save(root, sources = "myfuns.R")
    context <- context::context_load(context, new.env(parent = .GlobalEnv))
    obj <- rrq_controller(context, redux::hiredis())
    on.exit(obj$destroy())

    ## For testing, use: worker_command(obj)
    wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

    t <- obj$enqueue(getwd())
    res <- obj$task_wait(t, 2)
    expect_equal(res, getwd())
    expect_equal(getwd(), normalizePath(other))
  })
})

test_that("worker name", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  name <- ids::random_id()
  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS,
                      worker_name_base = name)
  expect_equal(wid, paste0(name, "_1"))
})

test_that("worker timeout", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  t <- as.integer(runif(1, min = 100, max = 10000))
  res <- obj$worker_config_save("localhost", timeout = t, copy_redis = TRUE)
  expect_equal(res$timeout, t)

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  id <- obj$message_send("TIMEOUT_GET")
  res <- obj$message_get_response(id, wid, timeout = 10)[[1]]
  expect_equal(res[["timeout"]], t)
  expect_lte(res[["remaining"]], t)
  obj$message_send("STOP")

  obj$worker_config_save("infinite", timeout = Inf, copy_redis = TRUE)

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS,
                       worker_config = "infinite")
  id <- obj$message_send("TIMEOUT_GET")
  res <- obj$message_get_response(id, wid, timeout = 10)[[1]]
  expect_equal(res[["timeout"]], Inf)
  expect_equal(res[["remaining"]], Inf)
  obj$message_send("STOP")
})

test_that("context job", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  ## For testing, use: worker_command(obj)
  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  id <- context::task_save(quote(sin(1)), context)
  t <- queuer:::queuer_task(id, context$root)

  r <- rrq_controller(context$id, redux::hiredis())

  r$queue_submit(t$id)
  expect_equal(t$wait(10, progress = PROGRESS), sin(1))
  expect_equal(t$status(), "COMPLETE")
  expect_equal(r$queue_length(), 0L)
})

test_that("log dir", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  r <- rrq_controller(context$id, redux::hiredis())

  on.exit(obj$destroy())

  obj$worker_config_save("localhost", log_path = "worker_logs_task",
                         copy_redis = TRUE)
  worker_command(obj)
  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  info <- obj$worker_info(wid)[[wid]]
  expect_equal(info$log_path, "worker_logs_task")

  expect_true(file.exists(file.path(root, "worker_logs_task")))

  id <- context::task_save(quote(noisydouble(1)), context)
  t <- queuer:::queuer_task(id, context$root)
  r$queue_submit(t$id)
  res <- t$wait(10, time_poll = 0.1, progress = PROGRESS)

  expect_true(file.exists(file.path(root, obj$db$get(t$id, "log_path"))))
  expect_is(t$log(), "context_log")
  x <- t$log()
  expect_true("start" %in% x$title)
  expect_equal(x$body[[which(x$title == "start")]], "doubling 1")
})

test_that("failed spawn", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  tmp <- basename(tempfile("myfuns_", fileext = ".R"))
  file.copy("myfuns.R", tmp)
  context <- context::context_save(root, sources = tmp)
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  file.remove(tmp)
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  dat <- evaluate_promise(
    try(worker_spawn(obj, 2, timeout = 2, progress = PROGRESS),
        silent = TRUE))

  expect_is(dat$result, "try-error")
  expect_match(dat$messages, "2 / 2 workers not identified in time",
               all = FALSE, fixed = TRUE)
  expect_match(dat$messages, "Log files recovered for 2 workers",
               all = FALSE, fixed = TRUE)
  expect_match(dat$output, "No such file or directory",
               all = FALSE, fixed = TRUE)
})

test_that("error", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  t1 <- obj$enqueue(only_positive(1))
  expect_equal(obj$task_wait(t1, 2, progress = PROGRESS), 1)

  t2 <- obj$enqueue(only_positive(-1))
  res <- obj$task_wait(t2, 2, progress = PROGRESS)
  expect_is(res, "rrq_task_error")
  expect_null(res$warnings)

  t3 <- obj$enqueue(nonexistant_function(-1))
  res <- obj$task_wait(t3, 2, progress = PROGRESS)
  expect_is(res, "rrq_task_error")
  expect_null(res$warnings)
})

test_that("error", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  t1 <- obj$enqueue(warning_then_error(2))
  r1 <- obj$task_wait(t1, 2, progress = PROGRESS)
  expect_is(r1, "rrq_task_error")
  expect_is(r1, "try-error")
  expect_is(r1$warnings, "list")
  expect_equal(length(r1$warnings), 2)
  expect_is(r1$warnings[[1]], "simpleWarning")
  expect_equal(r1$warnings[[1]]$message, "This is warning number 1")
  expect_equal(r1$warnings[[2]]$message, "This is warning number 2")

  expect_match(tail(r1$trace, 2)[[1]], "^warning_then_error")

  id <- context::task_save(quote(warning_then_error(2)), context)
  obj$queue_submit(id)
  t <- queuer:::queuer_task(id, context$root)
  r2 <- t$wait(10, time_poll = 0.1, progress = PROGRESS)

  expect_is(r2, "context_task_error")
  expect_is(r2$warnings, "list")
  expect_equal(length(r2$warnings), 2)
  expect_is(r2$warnings[[1]], "simpleWarning")
  expect_equal(r2$warnings[[1]]$message, "This is warning number 1")
  expect_equal(r2$warnings[[2]]$message, "This is warning number 2")

  expect_match(tail(r2$trace, 2)[[1]], "^warning_then_error")
})


test_that("task_position", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  context <- context::context_load(context, new.env(parent = .GlobalEnv))
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())

  t1 <- obj$enqueue(sin(1))
  t2 <- obj$enqueue(sin(1))
  t3 <- obj$enqueue(sin(1))

  expect_equal(obj$task_position(t1), 1L)
  expect_equal(obj$task_position(c(t1, t2, t3)), c(1L, 2L, 3L))
  expect_equal(obj$task_position("not a real task"), 0L)
  expect_equal(obj$task_position("not a real task", NA_integer_), NA_integer_)
  expect_equal(obj$task_position(c(t1, "not a real task"), NA_integer_),
               c(1L, NA_integer_))
})


test_that("call", {
  Sys.setenv(R_TESTS = "")
  root <- tempfile()
  context <- context::context_save(root, sources = "myfuns.R")
  envir <- new.env(parent = .GlobalEnv)
  context <- context::context_load(context, envir)
  obj <- rrq_controller(context, redux::hiredis())
  on.exit(obj$destroy())
  a <- 20L

  t1 <- obj$call(quote(noisydouble), 10, envir = envir)
  t2 <- obj$call(quote(noisydouble), a, envir = envir)
  t3 <- obj$call(quote(add), a, a, envir = envir)

  wid <- worker_spawn(obj, timeout = 5, progress = PROGRESS)

  expect_equal(obj$task_wait(t1, progress = PROGRESS), 20L)
  expect_equal(obj$task_wait(t2, progress = PROGRESS), 40L)
  expect_equal(obj$task_wait(t3, progress = PROGRESS), 40L)
})
