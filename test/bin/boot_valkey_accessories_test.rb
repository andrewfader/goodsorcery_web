require "test_helper"
require "open3"

# bin/boot_valkey_accessories, which CI runs before bin/kamal deploy. A fake
# ssh prints the server's containers and a fake kamal records what it was asked
# to do, so nothing leaves the machine.
class BootValkeyAccessoriesTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/boot_valkey_accessories").to_s

  setup do
    @dir = Dir.mktmpdir
    @kamal_log = File.join(@dir, "kamal.log")
    @ssh_log = File.join(@dir, "ssh.log")
    fake("ssh", %(echo "$*" >> "#{@ssh_log}"\nprintf '%s' "$FAKE_CONTAINERS"\nexit "${FAKE_SSH_STATUS:-0}"))
    fake("kamal", %(echo "$*" >> "#{@kamal_log}"))
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "boots every accessory missing from the server" do
    run_script(containers: "goodsorcery_web-web-abc running\n")

    assert_equal [ "accessory boot valkey-jobs", "accessory boot valkey-cache", "accessory boot valkey-cable" ], kamal_calls
  end

  test "leaves running accessories alone and starts stopped ones" do
    run_script(containers: "goodsorcery_web-valkey-jobs running\ngoodsorcery_web-valkey-cache exited\n" \
                           "goodsorcery_web-valkey-cable created\n")

    assert_equal [ "accessory start valkey-cache", "accessory start valkey-cable" ], kamal_calls
  end

  test "matches container names exactly" do
    run_script(containers: "goodsorcery_web-valkey-jobs-old running\ngoodsorcery_web-valkey-cache running\n" \
                           "goodsorcery_web-valkey-cable running\n")

    assert_equal [ "accessory boot valkey-jobs" ], kamal_calls
  end

  test "skips external roles" do
    run_script(containers: "", env: { "KAMAL_VALKEY_JOBS_EXTERNAL" => "1", "KAMAL_VALKEY_CABLE_EXTERNAL" => " 1 " })

    assert_equal [ "accessory boot valkey-cache" ], kamal_calls
  end

  test "does nothing when every accessory runs" do
    run_script(containers: %w[jobs cache cable].map { "goodsorcery_web-valkey-#{it} running\n" }.join)

    assert_empty kamal_calls
  end

  test "leaves a restarting accessory to the pre-deploy check" do
    _, status = run_script(containers: "goodsorcery_web-valkey-jobs restarting\ngoodsorcery_web-valkey-cache running\n" \
                                       "goodsorcery_web-valkey-cable running\n")

    assert status.success?
    assert_empty kamal_calls
  end

  test "connects like Kamal does" do
    run_script(containers: "", env: { "KAMAL_SSH_USER" => "ops", "KAMAL_SSH_PORT" => "2222" })

    assert_match "-p 2222 ops@example.test", File.read(@ssh_log)
  end

  test "fails without booting anything when SSH fails" do
    output, status = run_script(containers: "", env: { "FAKE_SSH_STATUS" => "255" })

    assert_not status.success?
    assert_match "couldn't list the containers on example.test", output
    assert_empty kamal_calls
  end

  private
    def fake(name, body)
      path = File.join(@dir, name)
      File.write(path, "#!/usr/bin/env bash\n#{body}\n")
      File.chmod(0o755, path)
    end

    def run_script(containers:, env: {})
      base = { "PATH" => "#{@dir}:#{ENV.fetch("PATH")}", "KAMAL_BIN" => File.join(@dir, "kamal"),
               "KAMAL_WEB_HOST" => "example.test", "FAKE_CONTAINERS" => containers }
      cleared = ENV.keys.grep(/\AKAMAL_(VALKEY_|SSH_|SERVICE)/).index_with(nil)
      Open3.capture2e(cleared.merge(base).merge(env), SCRIPT)
    end

    def kamal_calls = File.exist?(@kamal_log) ? File.readlines(@kamal_log, chomp: true) : []
end
