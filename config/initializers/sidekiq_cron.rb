# sidekiq-cron checks config/schedule.yml every cron_poll_interval seconds
# (30 by default) and enqueues each job at most once per cron tick, skipping
# ticks it missed. FlushIngestCountersJob runs every 10 seconds (a six-field
# cron line), so poll often enough to catch every tick: Sidekiq spreads the
# polls between half and one and a half times this interval.
Sidekiq::Cron.configure do |config|
  config.cron_poll_interval = 5
end
