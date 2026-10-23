Gem::Specification.new do |spec|
  spec.name = "activerecord-quack-adapter"
  spec.version = "0.1.0"
  spec.authors = ["Nico"]
  spec.summary = "Direct Quack protocol adapter for Active Record"
  spec.license = "MIT"
  spec.homepage = "https://github.com/sidequery/activerecord-quack-adapter"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*", "README.md", "LICENSE*"].select { |path| File.file?(path) } }
  spec.require_paths = ["lib"]
  spec.add_dependency "quack-ruby", "~> 0.1.0"
  spec.add_dependency "activerecord", ">= 7.2", "< 8.2"
end
