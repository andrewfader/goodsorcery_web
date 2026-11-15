require "test_helper"
require "kamal"

# config/deploy.yml decides through ERB which Valkey URLs reach the app in
# plain env and which as secrets. A mistake there can point production at the
# wrong server or put a password in `docker run` arguments, so render it the
# way Kamal does, with the variables a deploy machine would have.
class DeployConfigTest < ActiveSupport::TestCase
  HOST = "deploy.example.test".freeze
  ROLES = %w[JOBS CACHE CABLE].freeze
  SETTINGS = %w[IMAGE] + ROLES.flat_map do |role|
    %w[EXTERNAL URL MAXMEMORY POLICY MEMORY_LIMIT ARGS].map { "#{role}_#{it}" }
  end
  KEYS = %w[KAMAL_WEB_HOST GOODSORCERY_HOST] + SETTINGS.map { "KAMAL_VALKEY_#{it}" }

  # Kamal reads .kamal/secrets relative to the working directory.
  setup do
    @cwd = Dir.pwd
    Dir.chdir(Rails.root)
    @previous = ENV.to_h.slice(*KEYS)
    KEYS.each { ENV.delete(it) }
    ENV["KAMAL_WEB_HOST"] = HOST
    ENV["GOODSORCERY_HOST"] = "errors.example.test"
  end

  teardown do
    KEYS.each { ENV.delete(it) }
    ENV.update(@previous)
    Dir.chdir(@cwd)
  end

  test "by default the app reaches all three accessories through plain env" do
    assert_equal(
      { "REDIS_URL" => "redis://goodsorcery_web-valkey-jobs:6379/0",
        "REDIS_CACHE_URL" => "redis://goodsorcery_web-valkey-cache:6379/0",
        "REDIS_CABLE_URL" => "redis://goodsorcery_web-valkey-cable:6379/0" },
      app_env.clear.slice("REDIS_URL", "REDIS_CACHE_URL", "REDIS_CABLE_URL"))
    assert_empty app_env.secret_keys.grep(/VALKEY/)
  end

  test "by default the accessories run with their flags and memory limits" do
    assert_accessory "valkey-jobs", "--maxmemory 256mb --maxmemory-policy noeviction --appendonly yes --save \"\"", memory: "384m"
    assert_accessory "valkey-cache", "--maxmemory 128mb --maxmemory-policy allkeys-lru --save \"\" --appendonly no", memory: "160m"
    assert_accessory "valkey-cable", "--maxmemory 32mb --maxmemory-policy noeviction --save \"\" --appendonly no", memory: "64m"
    assert_includes accessory_run("valkey-jobs"), "valkey/valkey:9.1.3 --maxmemory"
  end

  test "an external role takes its URL from the secrets instead" do
    ENV["KAMAL_VALKEY_CACHE_EXTERNAL"] = "1"
    ENV["KAMAL_VALKEY_CACHE_URL"] = "rediss://:secret-pw@cache.example.test:6380/0"
    env = app_env

    assert_not env.clear.key?("REDIS_CACHE_URL")
    assert_equal "redis://goodsorcery_web-valkey-jobs:6379/0", env.clear["REDIS_URL"]
    assert_equal [ "REDIS_CACHE_URL:KAMAL_VALKEY_CACHE_URL" ], env.secret_keys.grep(/VALKEY/)
    assert_includes env.secrets_io.read, "REDIS_CACHE_URL=rediss://:secret-pw@cache.example.test:6380/0"
    assert_not_includes env.clear_args.join(" "), "secret-pw"
  end

  test "an external flag works without the URL in the shell, as with a secrets adapter" do
    ENV["KAMAL_VALKEY_JOBS_EXTERNAL"] = " 1 "

    assert_not app_env.clear.key?("REDIS_URL")
    assert_includes app_env.secret_keys, "REDIS_URL:KAMAL_VALKEY_JOBS_URL"
  end

  test "a URL without the external flag stops the render" do
    ENV["KAMAL_VALKEY_JOBS_URL"] = "rediss://jobs.example.test:6380/0"

    error = assert_raises(RuntimeError) { deploy_config }
    assert_match "KAMAL_VALKEY_JOBS_EXTERNAL=1", error.message
    assert_no_match "jobs.example.test", error.message
  end

  test "an external flag other than 1 stops the render" do
    ENV["KAMAL_VALKEY_CABLE_EXTERNAL"] = "true"

    assert_raises(RuntimeError, match: /must be 1 or unset/) { deploy_config }
  end

  test "blank values count as unset" do
    SETTINGS.each_with_index { |name, index| ENV["KAMAL_VALKEY_#{name}"] = index.even? ? "" : " \t " }

    assert_equal 3, app_env.clear.keys.grep(/\AREDIS_/).size
    assert_empty app_env.secret_keys.grep(/VALKEY/)
    assert_accessory "valkey-jobs", "--maxmemory 256mb --maxmemory-policy noeviction --appendonly yes --save \"\"", memory: "384m"
  end

  test "overrides replace the defaults, and extra arguments go last" do
    ENV["KAMAL_VALKEY_IMAGE"] = "redis:8.2.1"
    ENV["KAMAL_VALKEY_JOBS_MAXMEMORY"] = "1gb"
    ENV["KAMAL_VALKEY_JOBS_MEMORY_LIMIT"] = "1536m"
    ENV["KAMAL_VALKEY_CACHE_POLICY"] = "allkeys-lfu"
    ENV["KAMAL_VALKEY_CABLE_ARGS"] = "--io-threads 2 --syslog-ident 'valkey#cable'"

    assert_accessory "valkey-jobs", "redis:8.2.1 --maxmemory 1gb --maxmemory-policy noeviction", memory: "1536m"
    assert_includes accessory_run("valkey-cache"), "--maxmemory-policy allkeys-lfu"
    assert accessory_run("valkey-cable").end_with?(
      "--appendonly no --io-threads 2 --syslog-ident 'valkey#cable'")
  end

  private
    def deploy_config
      Kamal::Configuration.create_from(config_file: Pathname.new("config/deploy.yml"), destination: nil, version: "test")
    end

    def app_env
      deploy_config.role(:web).env(HOST)
    end

    def accessory_run(name)
      Kamal::Commands::Accessory.new(deploy_config, name: name).run(host: HOST).join(" ")
    end

    def assert_accessory(name, arguments, memory:)
      run = accessory_run(name)

      assert_includes run, arguments
      assert_includes run, "--memory \"#{memory}\""
    end
end
