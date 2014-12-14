# encoding: ascii
# api: fpm
# title: generic script source
# description: Utilizes `pack:` specifier from meta/comment block in script files
# type: package
# category: source
# version: 0.7
# state: beta
# architecture: all
# license: MITL
# author: mario#include-once:org
# config: <arg name="src-only" description="Only apply main pack: spec, do not recurse.">
# depends:
# pack: src.rb, README=README.txt, src/*.png
# 
# The "src" input is intended for packaging scripting language files.
# A top-level comment can hold per-file description fields, where the
# `pack:` lines simply reference other files to recurse and include.
#
#  → Other documentation/meta fields from the origin file are used as
#    package attributes (fpm --flag values still take precedence).
#
#  → The pack: line gives a simple comma-separated list of other scripts
#    or files to include.
#
#    · For instance `pack: src.rb, readme.txt, install.sh` will package
#      those files together with the main script.
#
#    · RECURSION: referenced files can itself specify a `pack:` line
#      onto other scripts/source/binary files.
#
#    · With `pack: m.py=main.py, b=b.txt` files can be renamed.
#
#    · Glob matching is also possible `pack: plugins/*.php`
#      Limited glob-rewriting via `doc/*.txt=manual/` even.
#      It's sort of working, use with care.
#
#    · A file can even exclude itself with `pack: empty.rb=`
#
#    Binary files can be referenced from a text/source file of course.
#    
#    Alternatively a concise spec.txt can be crafted to hold default
#    packaging settings for fpm. Which is a nice alternative to a "dir"
#    source or --inputs list for small projects.
#
#  → `depends:` lines are not yet used for packaging. They aren't
#    transcribed into system package (rpm/deb) control fields either.
#    (They're mostly intended for in-application plugin management.)
#

require "fpm/package"
require "fpm/util"
require "backports"
require "fileutils"
require "find"
require "socket"
require "pathname"

# Source package.
#
# Reads in the meta data comment block from the first specified file,
# recursively includes all pack:-mentioned scripts, while honoring
# src=dest filename specifiers.
#
class FPM::Package::Src < FPM::Package  # inheriting from ::Dir doesn't work
  
  option "--depends", :flag, "Traverse source files as mentioned in depends: field.", :default => false
  option "--only", :flag, "Only apply origin files pack: directive, do not recurse.", :default => false

  
  # Start from first specified source file.
  def input(path)
  
    # The init/main file should contain usable package meta fields
    if m = get_meta(path)
      # copy attributes over, if not present/overriden
      @name = m["id"] if not @name
      @version = m["version"] if not @version
      @epoch = m["epoch"] if not @epoch
      @architecture = m["architecture"] if not attributes[:architecture_given?]
      @description = "#{m['description']}\n#{m['comment']}" if not attributes[:description_given?]
      @url = m["url"] || m["homepage"] if not attributes[:url_given?]
      @category = m["category"] if not attributes[:category_given?]
      @priority = m["priority"] if not attributes[:priority_given?]
      @license = m["license"] if not attributes[:license_given?]
      @vendor = m["author"] if not attributes[:maintainer_given?]
      @maintainer = m["author"] if not attributes[:maintainer_given?]
      # pass all available attributes on in a hash
      @attributes[:meta] = m
          #@todo preparse and collect config: structures
    end

    # Assemble rewrite map
    # {
    #   rel/src1 => { src2=>dest, src3=>dest } ,
    #   rel/src2 => { src4=> .. }
    # }
    @map = {:spec_start => {path => path}}
    ::Dir.chdir(attributes[:chdir] || ".") do
      rewrite_map(path)
      logger.debug(@map)
#p @map      
      # Copy all referenced files.
      copied = {}
      @map.each do |from,pack|
        pack.each do |src,dest|
          # Each file can hold a primary declaration and override its target filename / make itself absent.
          if dest and @map[dest] and @map[dest][dest]
            dest = @map[dest][dest]
          end
          # References above the src/.. would also cross the staging_dir, give warning
          if dest and dest.match(/^\.\.\//)
            logger.warn("Referencing above ../ the basedir from #{from}")
          end
          # Else just apply pack{} map copying verbatim, possibly overwriting or duplicating files.
          if not copied[src+">"+dest]
#p "cp  #{src} to /#{dest}"
            real_copy("#{src}", "#{staging_path}/#{attributes[:prefix]}/#{dest}") if dest != ""
            copied[src+">"+dest] = 1
          end
        end
      end
    end
  end


  protected

  
  # Scan files for file,src=dest mapping lists.
  #
  # Each source file can specify references as `pack: two.sh, sub/three.py`
  # where each scripts´ subdirectory becomes the next base directory.
  #
  # The `dest` parameter is carried over from the previous old=new
  # filename pack{} map.
  #
  def rewrite_map(from, dest="")

    # lazy workaround to prevent neverending loops/references
    return if @map[from]
    
    # check if file is present, get meta data
    if not File.exists?(from)
      logger.warn("Skipping non-existent #{from} file")
      return
    elsif File.directory?(from)
      @map[from] = {}
      return
    else 
      packlist = get_meta(from)["pack"]  # adding [splitfn(from)[1]] itself would override renames
    end
    
    # relative dir and basename
    dir, fn = splitfn(from)   # fpm/ src.rb

    # @example
    #   from = fpm/src.r
    #          `pack: exe.rb, ../README, foo=bar, test/*`
    # @result
    #   pack[fpm/src.rb] = fpm/exe.rb=>fpm/exe.rb, README=>README, fpm/foo=>fpm/bar, fpm/test/123=>...}

    # iterate over listed references
    @map[from] = pack = {}
    packlist.each do |fnspec|

      # specifier can be one of: `src, src=dest, src*, dir/src*=dest/`
      src, dest = fnspec.split("=", 2) # dest can be nil (=use src basename), or empty "" (=skip file)

      # glob expansion      
      if src.match(/[\[\{\*\?]/)
        src = ::Dir.glob(dir + src)
        logger.warn("Nothing matched for '#{fnspec}' in '#{from}'") if src.empty?
      else
        src = [dir + src]
      end

      # combine with dest, and recursively scan each referenced source file
      src.each do |src|
        pack[consolidate(src)] = consolidate(dest ? dir+dest : src)
        rewrite_map(consolidate(src)) if not @attributes[:src_only?]
      end

    end
  end # def rewrite_map


  # split dir/name/ from basename 
  def splitfn(path)
    path =~ /\A  ((?: .*\/ )?)  ([^\/]+)  \Z/x
    return [$1, $2]
  end

  
  # remove ./ and dir/../ segments
  def consolidate(path)
    path = path.gsub(/(?<=^|\/)\.\//, "")    # strip out "./" self-referenting dirs
    path = path.gsub(/(?<=^|\/)(?!\.\.\/)[\w.-]+\/\.\.\//, "")    # consolidate "sub/../" relative paths
  end

  
  # Extract meta: key/values from source file
  def get_meta(path)

    # read file (first 8K would suffice)
    src = File.read(path, 1<<13, 0, :encoding=>'ASCII-8BIT')
    fields = { "pack" => "" }

    # extract first comment block,
    if src and src =~ /( \/\*+ .+? \*\/ | (?:[ \t]* \* | \#(?!!) [^\n]*\n)+ )/mix
      src = $1.gsub(/^[ \t\*\/\#]+/, "").to_s # does not honor indentation

      # split meta block from comment (on first empty line)
      src, fields["comment"] = src.split(/\r?\n\r?\n/, 2)  # eh, Ruby, Y U NO PROVIDE \R ?
      # split key: value fields
      fields.merge!(Hash[
         src.to_s.scan(/^([\w-]+): [[:blank:]]* ([^\n]* (?:\n (?![\w-]+:) [^\n]+)* )/x).map{ |k,v| [k.downcase, v] }
      ])

      # use input basename or id: field as package name
      fields["id"] = fields["id"] || path.match(/([^\/]+?)(\.\w+)?\Z/)[1]
      # split up pack: comma-separated list, don't expand src=dest yet
#p fields
      fields["pack"] = fields["pack"].split(/(?<!\\)[,\s]+/)
    else 
      fields["pack"] = []
    end
    return fields
  end # def meta


  # automatically recurses for and creates subdirectories when copying
  def real_copy(src, dest)
    if dest[-1] == "/"  # trailing slash indicates target dir
      dest += splitfn(src)[1]   # therefore copy src basename
    end
    if File.exists?(src)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp_r(src, dest)
    else
      logger.info("'#{src}' still missing, eh?")
    end
  end

end # class FPM::Package::Src
