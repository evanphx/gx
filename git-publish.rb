#!/usr/bin/env ruby

require 'pathname'
$:.unshift Pathname.new(__FILE__).realpath.dirname.to_s

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

repo = Grit::Repo.current

current = repo.resolve_rev "HEAD"
branch = repo.git.symbolic_ref({:q => true}, "HEAD").strip

branch_name = branch.gsub %r!^refs/heads/!, ""

origin_ref = repo.merge_ref branch_name

unless origin_ref
  puts "Sorry, it appears your current branch is not setup with merge info."
  puts "Please set 'branch.#{branch_name}.remote' and 'branch.#{branch_name}.merge'"
  puts "and try again."
  exit 1
end

origin = repo.resolve_rev origin_ref

# See if there are actually any commits to publish first.

if current == origin
  puts "Already up to date, no commits to publish."
  exit 0
end

# ok, there are commits, now make sure our origin and
# everything is update to date.

common = repo.find_ancestor(origin, current)

url = repo.merge_url branch_name

push_repo, push_branch = repo.merge_info branch_name
remote_hash = repo.remote_info push_repo, push_branch


if common != origin or remote_hash != origin
  puts "The upstream contains unmerged commits. Please update/pull first."
  if opts.verbose
    puts "Local branch:  #{current}"
    puts "Local origin:  #{origin}"
    puts "Remote origin: #{remote_hash}"
  end
  exit 1
end

print "Publishing local commits to #{url}... "

out = repo.git.push({:v => true}, push_repo, push_branch)
if $?.exitstatus != 0
  puts "error!"
  puts "Sorry, I'm not sure what happened. Here is what git said:"
  puts out
end

puts "done!"

