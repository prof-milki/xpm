# api: fpm
# title: Dependency matching
# description: resolves package names for other distributions, using distromatch/whohas
# type: filter
# category: dependency
# version: 0.1
# depends: bin:whohas | bin:distromatch
# license: MITL
# 
# Package names in -d dependency lists aren't universal across distributions.
# Which kind of complicates building targetted RPMs (or sometimes DEBs).
# 
# Distromatch or whohas.pl can resolve library and package names across
# different Linux systems. They're utilized in this filter to convert basenames
# between each other. Debian being the assumed reference point, you should
# standardize on theirs for specifying fpm -d lists.
# 
# A flag `-u deps=opensuse` flag can be used to specify the desired target
# distro/family.
#
#  → With `-u deps=fedora..debian` an inverse lookup is performed, only with
#    Distromatch though.
#
#  → Using whohas only plain package lists are fetched and distros and
#    package names searched raw.
#
# Optimum version matches aren't performed. (This is where it's getting even
# more complicated.)
#
# Obviously as these lookups can be time-consuming, you may wish to use either
# of the mentioned tools manually, and prepare per-package --dependencies lists
# yourself. Whohas is likely most revealing for that.


require "fpm/package"
require "fpm/util"

# Resolve package names cross-distro for dependency, suggest, conflicts, .. lists
class FPM::Package::Filter_Deps < FPM::Package

  def initialize()
    @dm = `which distromatch`
    @wh = `which whohas`
    logger.warning("Neither distromatch nor whohas are available.") unless (@dm or @wh)
    super
    @source = "debian"
    @target = "debian"
    @opts = []
  end
  
  # traverse lists
  def update(opts)
    
    # check for `-u deps=target` or `deps=source..target` options (option tokens are preseparated in command.rb)
    if opts.count >= 2
      @source, @target = opts
    elsif opts.count == 1
      @target = opts[0]
    end
    
    # replace all the things
    @dependencies = translate(@dependencies)
    @provides = translate(@provides)
    @replaces = translate(@replaces)
    @conflicts = translate(@conflicts)
  end

  # replace individual package references
  def translate(deps)
    renamed = []
    deps.each do |name|
      name =~ /([\w\.\+\-]+)(.*)/
      name, ver = [$1, $2]
      name = resolve(name)
      renamed << "#{name}#{ver}"
    end
    return renamed
  end

  # lookup tools
  def resolve(pkg)
    if target == source
      return pkg
    elsif @dm
      return distromatch(pkg)
    else
      return whohas(pkg)
    end
  end

  def distromatch(pkg)
    return pkg
  end

  def whohas(pkg)
    ls = `#{@wh} --no-threads --shallow -d #{@target} #{pkg}`
    if ls =~ /\w+\s+(\S+)/
      return $1
    else
      return pkg
    end
  end

end
