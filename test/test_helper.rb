require "minitest/autorun"
require "quack"

if ENV["QUACK_TEST_INSTALLED"]
  gem "activerecord", ENV.fetch("RAILS_VERSION")
  require "activerecord-quack-adapter"
  client = Gem.loaded_specs.fetch("quack-ruby")
  adapter = Gem.loaded_specs.fetch("activerecord-quack-adapter")
  raise "expected the precompiled client dependency" if client.platform.to_s == "ruby"
  raise "adapter loaded from the source checkout" if adapter.full_gem_path == File.expand_path("..", __dir__)
end

module LiveConnection
  def setup
    super
    skip "set QUACK_TEST_URI to run live integration tests" unless ENV["QUACK_TEST_URI"]
    @connection = Quack.connect(ENV.fetch("QUACK_TEST_URI"), auth_token: ENV.fetch("QUACK_TEST_TOKEN", "quack-ruby-test"))
  end
  def teardown
    @connection&.close if @connection&.connected?
    super
  end
end
