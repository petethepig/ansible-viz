#!/usr/bin/ruby
# vim: set ts=2 sw=2 tw=100:

require 'rubygems'
require 'bundler/setup'

require 'mustache'
require 'yaml'
require 'fileutils'
require 'optparse'
require 'ostruct'
require 'pp'

require 'ansible_viz/graphviz'
require 'ansible_viz/loader'
require 'ansible_viz/postprocessor'
require 'ansible_viz/resolver'
require 'ansible_viz/varfinder'
require 'ansible_viz/scoper'
require 'ansible_viz/grapher'
require 'ansible_viz/legend'
require 'ansible_viz/utils'

def get_options()
  options = default_options

  OptionParser.new do |o|
    o.banner = "Usage: ansible-viz.rb [options] <path-to-playbooks>"
    o.on("-o", "--output [FILE]", "Where to write output") do |fname|
      options.output_filename = fname
    end
    o.on("--[no-]tasks",
         "Include tasks.") do |val|
      options.show_tasks = val
    end
    o.on("--[no-]templates",
         "Include templates.") do |val|
      options.show_templates = val
    end
    o.on("--[no-]vardefaults",
         "Include variable defaults.") do |val|
      options.show_vardefaults = val
    end
    o.on("--[no-]main-defaults",
         "Include main defaults.") do |val|
      options.show_main_defaults = val
    end
    o.on("--[no-]varfiles",
         "Include variable files.") do |val|
      options.show_varfiles = val
    end
    o.on("--[no-]vars",
         "Include vars. Unused/undefined detection still has minor bugs.") do |val|
      options.show_vars = val
    end
    o.on("-eREGEXP", "--exclude-nodes=REGEXP",
         "Regexp of nodes to exclude from the graph, " \
         "e.g. 'role:myrole[1-3]|task:mytask[4-6]'") do |regex|
      options.exclude_nodes = Regexp.new(regex)
    end
    o.on("-EREGEXP", "--exclude-edges=REGEXP",
         "Regexp of edges to exclude from the graph, " \
         "e.g. 'role:myrole[1-3] -> task:mytask[4-6]'") do |regex|
      options.exclude_edges = Regexp.new(regex)
    end
    o.on("--no-usage",
         "Don't connect vars to where they're used.") do |val|
      options.show_usage = false
    end
    o.on("-v[LEVEL]", "--verbose=[LEVEL]",
         "Show debugging") do |level|
      $debug_level = level ? level.to_i : 2
    end
    o.on_tail("-h", "--help", "Show this message") do
      puts o
      exit
    end
  end.parse!

  if ARGV.length != 1
    abort("Must provide the path to your playbooks")
  end
  options.playbook_dir = ARGV.shift

  options
end

def divider(section)
  debug 2, "=" * tty_width
  debug 1, section + " ..."
  debug 2, ""
end

def graph_from_data(data, options)
  divider "Postprocessing"
  Postprocessor.new(options).process(data)

  divider "Resolving"
  Resolver.new.process(data)

  divider "Finding variables"
  VarFinder.new.process(data)

  divider "Scoping variables"
  Scoper.new.process(data)

  divider "Building graph"
  build_graph(data, options)
end

def build_graph(data, options)
  grapher = Grapher.new
  g = grapher.graph(data, options)
  g[:rankdir] = 'LR'
  g.is_cluster = true

#  unlinked = grapher.extract_unlinked(g)
  legend = Legend.new.mk_legend(options)

  superg = Graph.new
#  superg.add g, unlinked, legend
  superg.add g, legend
  superg[:rankdir] = 'LR'
  superg[:ranksep] = 2
  superg[:tooltip] = ' '
  superg
end

def write(graph, filename)
  Mustache.template_file = File.expand_path('../../../diagram.mustache', __FILE__)
  view = Mustache.new
  view[:now] = Time.now.strftime("%Y.%m.%d %H:%M:%S")

  view[:title] = "Ansible dependencies"
  view[:dotdata] = g2dot(graph)

  path = filename
  File.open(path, 'w') do |f|
    f.puts view.render
  end
  puts "Wrote #{path}"
end
