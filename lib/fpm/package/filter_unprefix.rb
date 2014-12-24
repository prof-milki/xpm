# Strips anything but the given prefix dir from staging_path.
#  -u unprefix=/usr/share/pkg/
# Will move the contents of that folder into the top level path.
#
# (It's kind of like the --chdir option for input,
# except that it works after input package extraction.)

require "fpm/package"
require "fpm/util"
require "fileutils"

# find manpages, compress them
class FPM::Package::Filter_unprefix < FPM::Package
  def update(opts=nil)

    if opts and opts.count == 1
      staging_from = "#{staging_path}/#{opts.first}"

      if File.exist?(staging_from)
        staging_keep = ::Dir.mktmpdir("package-#{type}-staging")

        if File.directory?(staging_keep)
          FileUtils.mv(::Dir.glob("#{staging_from}/*"), staging_keep)
          logger.debug("Exchanging staging path", :path => staging_path, :new => staging_keep)
          FileUtils.rm_r(staging_path)
          FileUtils.mv(staging_keep, staging_path)
        end

      else
        logger.error("Prefix directory doesn't exist in staging path", :path => opts.first)
      end

    end # opts
  end # update
end # class
