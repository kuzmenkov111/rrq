worker_config_read <- function(root, key) {
  root <- context::context_root_get(root)
  db <- root$db
  if (!db$exists(key, "worker_config")) {
    stop(sprintf("Invalid rrq worker configuration key '%s'", key))
  }
  config <- db$get(key, "worker_config")
  config$redis_host <- config$redis_host %||% Sys_getenv("REDIS_HOST")
  config$redis_port <- config$redis_port %||% Sys_getenv("REDIS_PORT")
  config
}

worker_config_save <- function(root, key, ...) {
  root <- context::context_root_get(root)
  config <- worker_config_make(...)
  root$db$set(key, config, "worker_config")
  invisible(config)
}

worker_config_make <- function(redis_host = NULL, redis_port = NULL,
                               time_poll = NULL, timeout = NULL,
                               log_path = NULL, heartbeat_period = NULL) {
  if (!is.null(redis_host)) {
    assert_scalar_character(redis_host)
  }
  if (!is.null(redis_port)) {
    assert_scalar_integer_like(redis_port)
  }
  if (!is.null(time_poll)) {
    assert_scalar_integer_like(time_poll)
  }
  if (!(is.null(timeout) || identical(timeout, Inf))) {
    assert_scalar_integer_like(timeout)
  }
  if (!is.null(log_path)) {
    assert_scalar_character(log_path)
  }
  if (!is.null(heartbeat_period)) {
    assert_scalar_integer_like(heartbeat_period)
  }
  config <- list(redis_host = redis_host,
                 redis_port = redis_port,
                 time_poll = time_poll,
                 timeout = timeout,
                 log_path = log_path,
                 heartbeat_period = heartbeat_period)
  config[!vlapply(config, is.null)]
}

## All this duplication is a bit horrid, but for now it'll have to do.
rrq_worker_config_save <- function(root, con, name,
                                   redis_host = NULL, redis_port = NULL,
                                   time_poll = NULL, timeout = NULL,
                                   log_path = NULL, heartbeat_period = NULL,
                                   copy_redis = FALSE, overwrite = TRUE) {
  write <- overwrite || !root$db$exists(name, "worker_config")
  if (write) {
    if (copy_redis) {
      redis_host <- con$config()$host
      redis_port <- con$config()$port
    }
    worker_config_save(root$path, name, redis_host, redis_port,
                       time_poll, timeout, log_path, heartbeat_period)
  } else {
    NULL
  }
}
