#!/usr/bin/ruby
# vim: set ts=2 sw=2:

require 'rubygems'
require './graphviz'
require 'fileutils'
require 'ostruct'
require 'pp'


class Grapher
  def graph(dict, options)
    g = Graph.new
    g[:tooltip] = ' '
    g[:label] = "Ansible dependencies"
    g[:fontsize] = 36

    add_nodes(g, dict)
    connect_playbooks(g, dict)
    connect_roles(g, dict)
    connect_usage(g, dict)

    decorate(g, dict, options)

    hide_dullness(g, dict)

    if not options.show_vars
      to_cut = g.nodes.find_all {|n| n.data[:type] == :var }
      g.cut(*to_cut)
    end

    g
  end

  def add_node(g, it)
    node = GNode[it[:fqn]]
    node.data = it
    it[:node] = node
    g.add(node)
  end

  def add_nodes(g, dict)
    dict[:role].each {|role|
      add_node(g, role)
      role[:task].each {|task|
        add_node(g, task)
        task[:var].each {|var| add_node(g, var) }
      }
      role[:varset].each {|vs|
        add_node(g, vs)
        vs[:var].each {|v| add_node(g, v) }
      }
    }
    dict[:playbook].each {|playbook|
      add_node(g, playbook)
      # Roles and tasks should already have nodes
    }
  end

  def add_edge(g, src, dst, tooltip, extra={})
    if src[:node] == nil
      raise "Bad src: #{src[:name]}"
    elsif dst[:node] == nil
      raise "Bad dst: #{dst[:name]}"
    end
    edge = GEdge[src[:node], dst[:node], {:tooltip => tooltip}.merge(extra)]
    g.add edge
    edge
  end

  def connect_playbooks(g, dict)
    dict[:playbook].each {|playbook|
      (playbook[:role] || []).each {|role|
        add_edge(g, playbook, role, "includes")
      }
      (playbook[:task] || []).each {|task|
        edge = add_edge(g, playbook, task, "calls task")
        style(edge, :call_task)
      }
    }
  end

  def connect_roles(g, dict)
    dict[:role].each {|role|
      (role[:role_deps] || []).each {|dep|
        edge = add_edge(g, role, dep, "calls extra task")
        style(edge, :call_extra_task)
      }

      role[:task].each {|task|
        add_edge(g, role, task, "calls task")
        task[:var].each {|var|
          if var[:defined]
            add_edge(g, task, var, "sets fact")
          end
        }
      }

      (role[:varset] || []).each {|vs|
        is_main = false  #vs[:name] == 'main'
        add_edge(g, role, vs, "defines var") unless is_main
        vs[:var].each {|v|
          add_edge(g, (is_main and role or vs), v, "defines var")
        }
      }
    }
  end

  def connect_usage(g, dict)
    dict[:role].each {|role|
      role[:task].each {|task|
        (task[:uses] || []).each {|var|
          edge = add_edge(g, task, var, "uses var")
          style(edge, :use_var)
        }
      }
    }
  end

  def hide_dullness(g, dict)
    # Given a>main>c, produce a>c
    g.nodes.find_all {|n|
      n.data[:name] == 'main' or n.data[:type] == :vardefaults
    }.each {|n|
      inc_node = n.inc_nodes[0]
      n.out.each {|e| e.snode = inc_node }
      n.out = Set[]
      g.cut n
    }

    # Elide var usage from things which define the var
    # Maybe do this in the model?
#    g.nodes.find_all {|n|
#      n.data[:type] == :var
#    }.each {|n|
#      n.inc
#    }
  end


  ########## DECORATE ###########

  class <<self
    def hsl(h, s, l)
      [h, s, l].map {|i| i / 100.0 }.join("+")
    end
  end

  @@style = {
    # Node styles
    :playbook => {:shape => 'folder',
                  :style => 'filled',
                  :fillcolor => hsl(66, 8, 100)},
    :role     => {:shape => 'house',
                  :style => 'filled',
                  :fillcolor => hsl(66, 24, 100)},
    :task     => {:shape => 'octagon',
                  :style => 'filled',
                  :fillcolor => hsl(66, 40, 100)},
    :varset   => {:shape => 'box3d',
                  :style => 'filled',
                  :fillcolor => hsl(33, 8, 100)},
    :var      => {:shape => 'oval',
                  :style => 'filled',
                  :fillcolor => hsl(33, 60, 80)},

    # Node decorations
    :role_unused   => {:style => 'filled',
                       :fillcolor => hsl(82, 24, 100)},
    :var_unused    => {:style => 'filled',
                       :fillcolor => hsl(88, 50, 100),
                       :fontcolor => hsl(0, 0, 0)},
    :var_undefined => {:style => 'filled',
                       :fillcolor => hsl(88, 100, 100)},
    :var_default   => {:style => 'filled',
                       :fillcolor => hsl(33, 90, 60),
                       :fontcolor => hsl(0, 0, 100)},
    :var_fact      => {:style => 'filled',
                       :fillcolor => hsl(33, 70, 100)},

    # Edge styles
    :use_var => {:color => 'lightgrey',
                 :tooltip => 'uses var'},
    :call_task => {:color => 'blue',
                   :style => 'dashed'},
    :call_extra_task => {:color => 'red'},
  }

  def style(node_or_edge, style)
    (@@style[style] || {}).each_pair {|k,v| node_or_edge[k] = v }
    node_or_edge
  end

  def decorate(g, dict, options)
    decorate_nodes(g, dict, options)

    dict[:role].each {|role|
      if role[:node].inc_nodes.empty?
        style(role[:node], :role_unused)
        role[:node][:tooltip] += '. Unused by any playbook'
      end
    }
  end

  def decorate_nodes(g, dict, options)
    g.nodes.each {|node|
      data = node.data
      type = data[:type]
      type = :varset if type == :vardefaults
      style(node, type)
      node[:label] = data[:name]
      typename = case type
                 when :varset then "Vars"
                 else type.to_s.capitalize
                 end
      node[:tooltip] = "#{typename} #{data[:fqn]}"

      case type
      when :var
        if data[:used].length == 0
          style(node, :var_unused)
          node[:tooltip] += '. UNUSED.'
        elsif not data[:defined]
          style(node, :var_undefined)
          node[:tooltip] += '. UNDEFINED.'
        elsif node.inc_nodes.all? {|n| n.data[:type] == :vardefaults }
          style(node, :var_default)
        elsif node.inc_nodes.all? {|n| n.data[:type] == :task }
          style(node, :var_fact)
        end
      end
    }
  end

  def mk_legend
    nodes = Hash[*([:playbook, :role, :task, :varset, :var].flat_map {|type|
      node = style(GNode[type.to_s.capitalize], type)
      [type, node]
    })]
    nodes[:varset][:label] = "Vars"
    nodes[:default] = style(GNode["Var default"], :var_default)
    nodes[:main_var] = style(GNode["Main var"], :var)
    nodes[:unused] = style(GNode["Unused var"], :var_unused)
    nodes[:undefined] = style(GNode["Undefined var"], :var_undefined)
    nodes[:fact] = style(GNode["Fact"], :var_fact)
    edges = [
      GEdge[nodes[:playbook], nodes[:role], {:label => "calls"}],
      style(GEdge[nodes[:playbook], nodes[:task], {:label => "calls extra task"}],
          :call_extra_task),
      GEdge[nodes[:role], nodes[:task], {:label => "defines"}],
      GEdge[nodes[:role], nodes[:varset], {:label => "defines"}],
      GEdge[nodes[:role], nodes[:default], {:label => "defaults define"}],
      GEdge[nodes[:role], nodes[:main_var], {:label => "main task defines"}],
      GEdge[nodes[:varset], nodes[:var], {:label => "defines"}],
      GEdge[nodes[:varset], nodes[:unused], {:label => "defines"}],
      style(GEdge[nodes[:task], nodes[:undefined], {:label => "uses"}], :use_var),
      GEdge[nodes[:task], nodes[:fact], {:label => "defines"}],
    ].flat_map {|e|
      n = GNode[e[:label]]
      n[:shape] = 'none'

      e1 = GEdge[e.snode, n]
      e2 = GEdge[n, e.dnode]
      [e1, e2].each {|ee|
        ee.attrs = e.attrs.dup
        ee[:label] = nil
      }
      e1[:arrowhead] = 'none'

      [e1, e2]
    }
    legend = Graph.new_cluster('legend')
    legend.add(*edges)
    legend[:bgcolor] = Grapher.hsl(15, 3, 100)
    legend[:label] = "Legend"
    legend[:fontsize] = 36
    legend
  end
end


# This is accessed as a global from graph_viz.rb, EWW
def rank_node(node)
  if node.data == nil
    return nil
  end
  case node.data[:type]
  when :playbook then :source
  when :task, :varset then :same
  when :var then :sink
  else nil
  end
end
