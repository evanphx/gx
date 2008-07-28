require 'rubygems'
require 'grit'

module Grit
  class Repo
    # Given +hashish+, parse it and return the hash
    # it refers to.
    #
    def resolve_rev(hashish)
      hash = @git.rev_parse({:verify => true}, hashish)
      return nil if $?.exitstatus != 0
      return hash.strip
    end

    # Given +left+ and +right+, detect and return their
    # closest common ancestor. Used to find the point to perform
    # merges from.
    #
    # +right+ defaults to the current HEAD.
    #
    def find_ancestor(left, right=nil)
      right ||= resolve_rev "HEAD"
      hash = @git.merge_base({}, left, right)
      return nil if $?.exitstatus != 0
      return hash.strip
    end

    def revs_between(left, right)
      @git.rev_list({}, "#{left}..#{right}").split("\n")
    end

    class UnmergedFile
      def initialize(name)
        @name = name
      end

      attr_accessor :original, :mine, :yours
    end

    def unmerged_files
      files = Hash.new { |h,k| h[k] = UnmergedFile.new(k) }
      @git.ls_files({:u => true}).split("\n").each do |line|
        mode, hash, stage, name = line.split(/\s+/, 4)
        case stage
        when "1"
          files[name].original = hash
        when "2"
          files[name].yours = hash
        when "3"
          files[name].mine = hash
        end
      end

      return files
    end

    def Grit.rebase_dir
      if File.directory? ".dotest"
        return ".dotest"
      elsif File.directory? ".git/rebase"
        return ".git/rebase"
      else
        raise "No rebase info found."
      end
    end

    def am_info
      info = {}
      File.open("#{Grit.rebase_dir}/info") do |f|
        f.readlines.each do |line|
          line.strip!
          break if line.empty?
          key, val = line.split(": ")
          info[key.downcase.to_sym] = val
        end
      end

      if subject = info[:subject]
        subject.gsub!(/^\[PATCH\] /,"")
      end

      return info
    end

    def to_be_committed
      @git.diff_index({:cached => true, :name_only => true}, "HEAD").split("\n")
    end

    def path2ref(name)
      name.gsub %r!^refs/heads/!, ""
    end

    def merge_ref(branch)
      repo = @git.config({}, "branch.#{branch}.remote").strip
      ref =  @git.config({}, "branch.#{branch}.merge").strip
      path = "#{repo}/#{path2ref(ref)}"
      return path
    end
  end
end
