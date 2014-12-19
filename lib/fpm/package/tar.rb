require "backports" # gem backports
require "fpm/package"
require "fpm/util"
require "fileutils"
require "fpm/package/dir"

# Use a tarball as a package.
#
# This provides no metadata. Both input and output are supported.
class FPM::Package::Tar < FPM::Package

  # Input a tarball. Compressed tarballs should be OK.
  def input(input_path)
    # use part of the filename as the package name
    self.name = File.basename(input_path).split(".").first

    # Unpack the tarball to the build path before ultimately moving it to
    # staging.
    args = ["-xf", input_path, "-C", build_path]

    # Add the tar compression flag if necessary
    with(tar_compression_flag(input_path)) do |flag|
      args << flag unless flag.nil?
    end

    safesystem("tar", *args)

    # use dir to set stuff up properly, mainly so I don't have to reimplement
    # the chdir/prefix stuff special for tar.
    dir = convert(FPM::Package::Dir)
    if attributes[:chdir]
      dir.attributes[:chdir] = File.join(build_path, attributes[:chdir])
    else
      dir.attributes[:chdir] = build_path
    end

    cleanup_staging
    # Tell 'dir' to input "." and chdir/prefix will help it figure out the
    # rest.
    dir.input(".")
    @staging_path = dir.staging_path
    dir.cleanup_build
  end # def input

  # Output a tarball.
  #
  # If the output path ends predictably (like in .tar.gz) it will try to obey
  # the compression type.
  def output(output_path)
    output_check(output_path)
    # Pack tarball in the staging path
    args = tar_compression_flag(output_path).compact \
         + [File.absolute_path(output_path), "."]

    ::Dir::chdir(staging_path) do
      safesystem(*args)
    end
  end # def output

  # Generate the proper tar flags based on the path name.
  def tar_compression_flag(path)
    case path
      when /\.tar\.bz2$|\.tbz2$/
        return ["tar", "-cjf"]
      when /\.tar\.gz$|\.tgz$/
        return ["tar", "-czf"]
      when /\.tar\.xz$|\.txz$/
        return ["tar", "-cJf"]
      when /\.pax$/
        return ["pax", "-wf"]
      when /\.pax\.gz$/
        return ["pax", "-wzf"]
      when /\.pax\.xz$/
        return ["pax", "-wJf"]
      when /\.pax\.bz2$/
        return ["pax", "-wjf"]
      when /\.cpio$/
        return ["pax", "-x" "cpio", "-wf"]
      when /\.cpio.gz$/
        return ["pax", "-x" "cpio", "-wzf"]
      else
        return ["tar", "-cf"]
    end
  end # def tar_compression_flag
end # class FPM::Package::Tar
