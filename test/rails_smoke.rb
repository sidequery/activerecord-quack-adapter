ENV["RAILS_ENV"] = "test"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "rack/mock"
require "activerecord-quack-adapter"

class QuackSmokeApp < Rails::Application
  config.root = File.expand_path("fixtures/rails", __dir__)
  config.paths["config/database"] = [File.join(config.root, "database.yml")]
  config.eager_load = false
  config.logger = Logger.new(File::NULL)
  config.secret_key_base = "quack-ruby-integration-test-only"
  config.hosts.clear
end

QuackSmokeApp.initialize!
class SmokeWidget < ActiveRecord::Base
  self.table_name = "quack_rails_smoke"
end
class SmokeController < ActionController::API
  def index
    render json: {names: SmokeWidget.order(:id).pluck(:name)}
  end
  def create
    record = SmokeWidget.create!(name: params.require(:name))
    render json: {id: record.id}, status: :created
  end
end
Rails.application.routes.draw do
  get "/widgets", to: "smoke#index"
  post "/widgets", to: "smoke#create"
end

connection = ActiveRecord::Base.connection
begin
  connection.create_table(:quack_rails_smoke, force: true) { |table| table.string :name }
  request = Rack::MockRequest.new(Rails.application)
  response = request.post("/widgets", "CONTENT_TYPE" => "application/json", input: JSON.generate(name: "Rails over Quack"))
  raise "POST failed: #{response.status} #{response.body}" unless response.status == 201 && JSON.parse(response.body)["id"].is_a?(Integer)
  response = request.get("/widgets")
  raise "GET failed: #{response.status} #{response.body}" unless response.status == 200 && JSON.parse(response.body) == {"names" => ["Rails over Quack"]}
  puts "Rails #{Rails.version}: boot, database.yml, POST and GET passed"
ensure
  connection.drop_table(:quack_rails_smoke, if_exists: true)
  ActiveRecord::Base.connection_pool.disconnect!
end
