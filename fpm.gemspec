Gem::Specification.new do |spec|
  files = []
  dirs = %w{lib bin templates}
  dirs.each do |dir|
    files += Dir["#{dir}/**/*"]
  end

  files << "LICENSE"
  files << "CONTRIBUTORS"
  files << "CHANGELIST"

  spec.name = "fpm"
  spec.version = "0.2.30"
  spec.summary = "fpm - package building and mangling"
  spec.description = "Turn directories into packages. Fix broken packages. Win the package building game."
  spec.add_dependency("json")
  spec.files = files
  spec.require_paths << "lib"
  spec.bindir = "bin"
  spec.executables << "fpm"
  spec.executables << "fpm-npm"

  spec.author = "Jordan Sissel"
  spec.email = "jls@semicomplete.com"
  spec.homepage = "https://github.com/jordansissel/fpm"
end

