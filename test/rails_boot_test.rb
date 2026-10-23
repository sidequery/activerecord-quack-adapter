require_relative "test_helper"
require "open3"

class RailsBootTest < Minitest::Test
  def test_rails_boot_and_requests_use_database_yml
    skip "set QUACK_TEST_URI to run Rails integration" unless ENV["QUACK_TEST_URI"]
    root = File.expand_path("..", __dir__)
    load_path = ENV["QUACK_TEST_INSTALLED"] ? [] : ["-I", "#{root}/lib"]
    output, status = Open3.capture2e(RbConfig.ruby, *load_path, "#{root}/test/rails_smoke.rb")
    assert status.success?, output
    assert_includes output, "boot, database.yml, POST and GET passed"
  end
end
