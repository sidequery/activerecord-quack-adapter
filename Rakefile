require "rake/testtask"
require "fileutils"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/**/*_test.rb"
end
task default: :test
desc "Build the source gem"
task :package do
  FileUtils.mkdir_p("pkg")
  sh "gem", "build", "activerecord-quack-adapter.gemspec", "--output", "pkg/activerecord-quack-adapter-0.1.0.gem"
end
