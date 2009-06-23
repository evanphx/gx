#!/usr/bin/env ruby

# TODO:
# * Handle a conflict in a remote commit that is in a renamed file.

$:.unshift File.dirname(__FILE__)

require 'enhance'
require 'optparse'
require 'ostruct'
require 'fileutils'
require 'readline'

opts = OpenStruct.new

op = OptionParser.new do |o|
  o.on "-z", "--analyze", "Output information on what update would do" do
    opts.analyze = true
  end

  o.on "-v", "--verbose", "Be verbose" do
    opts.verbose = true
  end

  o.on "--debug", "Show all git commands run" do
    Grit.debug = true
  end

  o.on "-q", "--quiet", "Show the minimal output" do
    opts.quiet = true
  end
end

op.parse!(ARGV)

STDOUT.sync = true

class Update
    HELP = <<-TXT
You're currently inside the conflict resolver. The following commands
are available to help you.

When the conflict resolver is first started, the contents of the file
will contain the file populated with conflict markers for you to edit.

[D]iff       View the diffs between the (original version and local version)
                and (original version and remote version).
[E]dit       Launch your editor to edit the file.
[T]ool       Run git-mergetool on the file.
[O]riginal   Set the contents of the file to the original version. This is
                version from the common ancestor of your commit and the remote
                commit.
[M]ine       Set the contents of the file to be your version.
[R]emote     Set the contents of the file to be the remote version.
co[N]flict   Set the contents of the file to contain the merged between the
                local version and remote version, with conflict markers.
[P]rompt     Launch a subshell to deal with the conflict. Simply exit
                from the shell to continue with conflict resolution.
[I]nfo       View information about the commit and the current file.
[A]bort      Cancel the update all together, restore everything to before
                the update was started.
[C]ontinue   You're done dealing with this conflict, move on to the next one.
[H]elp       Detail all available options, you're looking at it now.
    TXT


  def initialize(opts)
    @opts = opts
    @repo = Grit::Repo.current

    @current = @repo.resolve_rev "HEAD"
    @branch = @repo.git.symbolic_ref({:q => true}, "HEAD").strip

    @branch_name = @branch.gsub %r!^refs/heads/!, ""

    @origin_ref = @repo.merge_ref @branch_name

    unless @origin_ref
      puts "Sorry, it appears you're current branch is not setup with merge info."
      puts "Please set 'branch.#{@branch_name}.remote' and 'branch.#{@branch_name}.merge'"
      puts "and try again."
      exit 1
    end
  end

  def fetch
    print "Fetching new commits: "
    out = @repo.git.fetch :timeout => false
    puts "done."

    # TODO parse +out+ for details to show the user.
  end

  def includes_conflict_markers?(path)
    /^<<<<<<< HEAD/.match(File.read(path))
  end

  def cat_file(ref, file)
    File.open(file, "w") do |f|
      f << @repo.git.cat_file({}, ref)
    end
  end

  def handle_unmerged(patch_info, files)
    files.each do |name, info|
      system "cp #{name} .git/with_markers"

      puts
      puts "Conflict discovered in '#{name}'"

      loop do

        # If there are conflict markers, default is edit.
        if includes_conflict_markers?(name)
          default = "E"

          # otherwise it's continue.
        else
          default = "C"
        end

        ans = Readline.readline "Select: [D]iff, [E]dit, [C]ontinue, [H]elp: [#{default}] "
        ans = default if ans.empty?
        want = ans.downcase[0]
        case want
        when ?d
          orig = ".git/diff/original/#{name}"
          FileUtils.mkdir_p File.dirname(orig)
          cat_file info.original, orig

          mine = ".git/diff/mine/#{name}"
          FileUtils.mkdir_p File.dirname(mine)
          cat_file info.mine, mine

          remote = ".git/diff/remote/#{name}"
          FileUtils.mkdir_p File.dirname(remote)
          cat_file info.yours, remote

          system "cd .git/diff; diff -u original/#{name} mine/#{name}"
          system "cd .git/diff; diff -u original/#{name} remote/#{name}"
          system "rm -rf .git/diff"
        when ?e
          system "#{ENV['EDITOR']} #{name}"
        when ?t
          system "git mergetool #{name}"
        when ?o
          cat_file info.original, name
        when ?m
          cat_file info.mine, name
        when ?r
          cat_file info.yours, name
        when ?n
          system "cp .git/with_markers #{name}"
        when ?p
          puts "Starting a sub-shell to handle conflicts for #{name}."
          puts "Exit the shell to continue resolution."
          system "$SHELL"
        when ?i
          puts "Current file: #{name}"
          puts "Current commit:"
          puts "  Subject: #{patch_info[:subject]}"
          puts "  Date:    #{patch_info[:date]}"
          puts "  Author:  #{patch_info[:author]} (#{patch_info[:email]})"
        when ?a
          raise "abort!"
        when ?h
          puts HELP
        when ?c
          if includes_conflict_markers?(name)
            puts
            puts "It looks like this file still contains conflict markers."
            a = Readline.readline "Are you sure that you want to commit it? [Y/N]: "
            break if a.downcase[0] == ?y
          else
            break
          end
        else
          puts "Unknown option. Try again."
        end
      end

      File.unlink ".git/with_markers" rescue nil
      @repo.git.add({}, name)
    end
  end

  def analyze
    puts "Automatically merging in refs from: #{@origin_ref} / #{@origin[0,7]}"
    puts "Closest ancestor between HEAD and origin: #{@common[0,7]}"
    puts

    if @to_receive.empty?
      puts "Current history is up to date."
      exit 0
    end

    puts "#{@to_receive.size} new commits."
    if @opts.verbose
      system "git log --pretty=oneline #{@common}..#{@origin_ref}"
      puts
    end

    puts "#{@to_replay.size} commits to adapt."
    if @opts.verbose
      system "git log --pretty=oneline #{@common}..HEAD"
      puts
    end
  end

  def run

    fetch

    @origin = @repo.resolve_rev @origin_ref

    @common = @repo.find_ancestor(@origin, @current)

    @to_replay = @repo.revs_between(@common, @current)
    @to_receive = @repo.revs_between(@common, @origin)

    if @opts.analyze
      analyze
      exit 0
    end

    if @to_receive.empty?
      puts "Up to date."
      exit 0
    end

    if @opts.verbose
      puts "Extracting commits between #{@common[0,7]} and HEAD..."
    end

    # DANGER. Before here, we can abort anytime, after here, we're making
    # changes, so we need to be able to recover.
    #
    begin
      port_changes
    rescue Exception => e
      puts "Error detected, aborting update: #{e.message} (#{e.class})"
      puts e.backtrace
      recover
      exit 1
    end
  end

  def recover
    @repo.git.reset({:hard => true}, @current)
    @repo.git.checkout({}, @branch.gsub(%r!^refs/heads/!, ""))

    if @used_wip
      @repo.git.reset({:mixed => true}, "HEAD^")
    end

    system "rm -rf #{Grit.rebase_dir}" rescue nil
  end

  def sh(cmd)
    Grit.log cmd if Grit.debug
    out = `#{cmd}`
    Grit.log out if Grit.debug
  end

  def port_changes
    # Switch back in time so we can re-apply commits. checkout
    # will return non-zero if there it can't be done. In that case
    # we perform a WIP commit, and unwind that WIP commit later,
    # leaving the working copy the same way it was.

    @used_wip = false

    list = @repo.git.ls_files(:m => true).split("\n")
    if list.size > 0
      @repo.git.commit({:m => "++WIP++", :a => true})
      @used_wip = true

      # Because we've introduced a new commit, we need to repoint current.
      @current = @repo.resolve_rev "HEAD"

      # And the list of commits to replay.
      @to_replay = @repo.revs_between(@common, @current)

      # Ok, try again.
      error = @repo.git.checkout({:q => true}, @origin)
      if $?.exitstatus != 0
        # Ok, give up.
        recover

        # Now tell the user what happened.
        puts "ERROR: Sorry, 'git checkout' can't figure out how to properly switch"
        puts "the working copy. Please fix this and run 'git update' again."
        puts "Here is the error that 'git checkout' reported:"
        puts error
        exit 1
      end
    else
      @repo.git.checkout({:q => true}, @origin)
    end

    sh "git format-patch --full-index --stdout #{@common}..#{@current} > .git/update-patch"
    out = sh "git am --rebasing < .git/update-patch 2> /dev/null"
    while $?.exitstatus != 0
      info = @repo.am_info
      if @opts.verbose
        if info[:subject] == "++WIP++"
          puts "Conflict detected in working copy."
        else
          puts "Conflict detected applying: #{info[:subject]}"
        end
      end

      unmerged = @repo.unmerged_files
      handle_unmerged info, unmerged

      if @repo.to_be_committed.empty?
        out = @repo.git.am({:skip => true, "3" => true})
      else
        out = @repo.git.am({:resolved => true, "3" => true})
      end
    end

    # Remove the patch we created contain all the rebased commits
    File.unlink ".git/update-patch" rescue nil

    rev = @repo.resolve_rev "HEAD"

    # Update the branch ref to point to our new commit

    @repo.git.update_ref({:m => "updated"}, @branch, rev, @current)
    @repo.git.symbolic_ref({}, "HEAD", @branch)

    # If we inserted a WIP commit on the top, remove the commit, but leave
    # the work.
    if @used_wip
      @repo.git.reset({:mixed => true}, "HEAD^")
    end

    puts
    puts "Updated. Imported #{@to_receive.size} commits, HEAD now pointed to #{rev[0,7]}."
    puts

    unless @opts.quiet
      system "git diff --stat #{@common}..#{@origin}"
    end

  end
end

Update.new(opts).run
