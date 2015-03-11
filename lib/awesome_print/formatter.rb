autoload :CGI, 'cgi'
require 'shellwords'

require 'awesome_print/formatters/base'
require 'awesome_print/formatters/array'
require 'awesome_print/formatters/hash'
require 'awesome_print/formatters/object'
require 'awesome_print/formatters/set'
require 'awesome_print/formatters/struct'
require 'awesome_print/formatters/class'
require 'awesome_print/formatters/file'
require 'awesome_print/formatters/dir'

module AwesomePrint
  class Formatter

    CORE = [ :array, :bigdecimal, :class, :dir, :file, :hash, :method, :rational, :set, :struct, :unboundmethod ]
    DEFAULT_LIMIT_SIZE = 7

    attr_reader :options, :inspector, :indentation

    def initialize(inspector)
      @inspector   = inspector
      @options     = inspector.options
      @indentation = @options[:indent].abs
    end

    # Main entry point to format an object.
    #------------------------------------------------------------------------------
    def format(object, type = nil)
      core_class = cast(object, type)
      awesome = if core_class != :self
        send(:"awesome_#{core_class}", object) # Core formatters.
      else
        awesome_self(object, type) # Catch all that falls back to object.inspect.
      end
      awesome
    end

    # Hook this when adding custom formatters. Check out lib/awesome_print/ext
    # directory for custom formatters that ship with awesome_print.
    #------------------------------------------------------------------------------
    def cast(object, type)
      CORE.grep(type)[0] || :self
    end

    # Pick the color and apply it to the given string as necessary.
    #------------------------------------------------------------------------------
    def colorize(str, type)
      str = CGI.escapeHTML(str) if @options[:html]
      if @options[:plain] || !@options[:color][type] || !@inspector.colorize?
        str
      #
      # Check if the string color method is defined by awesome_print and accepts
      # html parameter or it has been overriden by some gem such as colorize.
      #
      elsif str.method(@options[:color][type]).arity == -1 # Accepts html parameter.
        str.send(@options[:color][type], @options[:html])
      else
        str = %Q|<kbd style="color:#{@options[:color][type]}">#{str}</kbd>| if @options[:html]
        str.send(@options[:color][type])
      end
    end

    def indent
      ' ' * @indentation
    end

    def outdent
      ' ' * (@indentation - @options[:indent].abs)
    end

    def indented
      @indentation += @options[:indent].abs
      yield
    ensure
      @indentation -= @options[:indent].abs
    end

    # To support limited output, for example:
    #
    # ap ('a'..'z').to_a, :limit => 3
    # [
    #     [ 0] "a",
    #     [ 1] .. [24],
    #     [25] "z"
    # ]
    #
    # ap (1..100).to_a, :limit => true # Default limit is 7.
    # [
    #     [ 0] 1,
    #     [ 1] 2,
    #     [ 2] 3,
    #     [ 3] .. [96],
    #     [97] 98,
    #     [98] 99,
    #     [99] 100
    # ]
    #------------------------------------------------------------------------------
    def should_be_limited?
      @options[:limit] == true or (@options[:limit].is_a?(Fixnum) and @options[:limit] > 0)
    end

    def limited(data, width, is_hash = false)
      limit = get_limit_size
      if data.length <= limit
        data
      else
        # Calculate how many elements to be displayed above and below the separator.
        head = limit / 2
        tail = head - (limit - 1) % 2

        # Add the proper elements to the temp array and format the separator.
        temp = data[0, head] + [ nil ] + data[-tail, tail]

        if is_hash
          temp[head] = "#{indent}#{data[head].strip} .. #{data[data.length - tail - 1].strip}"
        else
          temp[head] = "#{indent}[#{head.to_s.rjust(width)}] .. [#{data.length - tail - 1}]"
        end

        temp
      end
    end

    # Format object.methods array.
    #------------------------------------------------------------------------------
    def methods_array(a)
      a.sort! { |x, y| x.to_s <=> y.to_s }                  # Can't simply a.sort! because of o.methods << [ :blah ]
      object = a.instance_variable_get('@__awesome_methods__')
      tuples = a.map do |name|
        if name.is_a?(Symbol) || name.is_a?(String)         # Ignore garbage, ex. 42.methods << [ :blah ]
          tuple = if object.respond_to?(name, true)         # Is this a regular method?
            the_method = object.method(name) rescue nil     # Avoid potential ArgumentError if object#method is overridden.
            if the_method && the_method.respond_to?(:arity) # Is this original object#method?
              method_tuple(the_method)                      # Yes, we are good.
            end
          elsif object.respond_to?(:instance_method)              # Is this an unbound method?
            method_tuple(object.instance_method(name)) rescue nil # Rescue to avoid NameError when the method is not
          end                                                     # available (ex. File.lchmod on Ubuntu 12).
        end
        tuple || [ name.to_s, '(?)', '?' ]                  # Return WTF default if all the above fails.
      end

      width = (tuples.size - 1).to_s.size
      name_width = tuples.map { |item| item[0].size }.max || 0
      args_width = tuples.map { |item| item[1].size }.max || 0

      data = tuples.inject([]) do |arr, item|
        index = indent
        index << "[#{arr.size.to_s.rjust(width)}]" if @options[:index]
        indented do
          arr << "#{index} #{colorize(item[0].rjust(name_width), :method)}#{colorize(item[1].ljust(args_width), :args)} #{colorize(item[2], :class)}"
        end
      end

      "[\n" << data.join("\n") << "\n#{outdent}]"
    end

    # Format hash keys as plain strings regardless of underlying data type.
    #------------------------------------------------------------------------------
    def plain_single_line
      plain, multiline = @options[:plain], @options[:multiline]
      @options[:plain], @options[:multiline] = true, false
      yield
    ensure
      @options[:plain], @options[:multiline] = plain, multiline
    end

    def align(value, width)
      if @options[:multiline]
        if @options[:indent] > 0
          value.rjust(width)
        elsif @options[:indent] == 0
          indent + value.ljust(width)
        else
          indent[0, @indentation + @options[:indent]] + value.ljust(width)
        end
      else
        value
      end
    end

    def left_aligned
      current, @options[:indent] = @options[:indent], 0
      yield
    ensure
      @options[:indent] = current
    end

    def awesome_instance(o)
      "#{o.class}:0x%08x" % (o.__id__ * 2)
    end

    private

    # Catch all method to format an arbitrary object.
    #------------------------------------------------------------------------------
    def awesome_self(object, type)
      if @options[:raw] && object.instance_variables.any?
        return awesome_object(object)
      elsif hash = convert_to_hash(object)
        awesome_hash(hash)
      else
        colorize(object.inspect.to_s, type)
      end
    end

    # Format an array.
    #------------------------------------------------------------------------------
    def awesome_array(a)
      AwesomePrint::Formatters::Array.new(self, a).call
    end

    # Format a hash. If @options[:indent] if negative left align hash keys.
    #------------------------------------------------------------------------------
    def awesome_hash(h)
      AwesomePrint::Formatters::Hash.new(self, h).call
    end

    # Format an object.
    #------------------------------------------------------------------------------
    def awesome_object(o)
      AwesomePrint::Formatters::Object.new(self, o).call
    end

    # Format a set.
    #------------------------------------------------------------------------------
    def awesome_set(s)
      AwesomePrint::Formatters::Set.new(self, s).call
    end

    # Format a Struct.
    #------------------------------------------------------------------------------
    def awesome_struct(s)
      AwesomePrint::Formatters::Struct.new(self, s).call
    end

    # Format Class object.
    #------------------------------------------------------------------------------
    def awesome_class(c)
      AwesomePrint::Formatters::Class.new(self, c).call
    end

    # Format File object.
    #------------------------------------------------------------------------------
    def awesome_file(f)
      AwesomePrint::Formatters::File.new(self, f).call
    end

    # Format Dir object.
    #------------------------------------------------------------------------------
    def awesome_dir(d)
      AwesomePrint::Formatters::Dir.new(self, d).call
    end

    # Format BigDecimal object.
    #------------------------------------------------------------------------------
    def awesome_bigdecimal(n)
      colorize(n.to_s("F"), :bigdecimal)
    end

    # Format Rational object.
    #------------------------------------------------------------------------------
    def awesome_rational(n)
      colorize(n.to_s, :rational)
    end

    # Format a method.
    #------------------------------------------------------------------------------
    def awesome_method(m)
      name, args, owner = method_tuple(m)
      "#{colorize(owner, :class)}##{colorize(name, :method)}#{colorize(args, :args)}"
    end
    alias :awesome_unboundmethod :awesome_method

    # Return [ name, arguments, owner ] tuple for a given method.
    #------------------------------------------------------------------------------
    def method_tuple(method)
      if method.respond_to?(:parameters) # Ruby 1.9.2+
        # See http://ruby.runpaint.org/methods#method-objects-parameters
        args = method.parameters.inject([]) do |arr, (type, name)|
          name ||= (type == :block ? 'block' : "arg#{arr.size + 1}")
          arr << case type
            when :req        then name.to_s
            when :opt, :rest then "*#{name}"
            when :block      then "&#{name}"
            else '?'
          end
        end
      else # See http://ruby-doc.org/core/classes/Method.html#M001902
        args = (1..method.arity.abs).map { |i| "arg#{i}" }
        args[-1] = "*#{args[-1]}" if method.arity < 0
      end

      # method.to_s formats to handle:
      #
      # #<Method: Fixnum#zero?>
      # #<Method: Fixnum(Integer)#years>
      # #<Method: User(#<Module:0x00000103207c00>)#_username>
      # #<Method: User(id: integer, username: string).table_name>
      # #<Method: User(id: integer, username: string)(ActiveRecord::Base).current>
      # #<UnboundMethod: Hello#world>
      #
      if method.to_s =~ /(Unbound)*Method: (.*)[#\.]/
        unbound, klass = $1 && '(unbound)', $2
        if klass && klass =~ /(\(\w+:\s.*?\))/  # Is this ActiveRecord-style class?
          klass.sub!($1, '')                    # Yes, strip the fields leaving class name only.
        end
        owner = "#{klass}#{unbound}".gsub('(', ' (')
      end

      [ method.name.to_s, "(#{args.join(', ')})", owner.to_s ]
    end

    # Utility methods.
    #------------------------------------------------------------------------------
    def convert_to_hash(object)
      if ! object.respond_to?(:to_hash)
        return nil
      end
      if object.method(:to_hash).arity != 0
        return nil
      end

      hash = object.to_hash
      if ! hash.respond_to?(:keys) || ! hash.respond_to?('[]')
        return nil
      end

      return hash
    end

    def get_limit_size
      @options[:limit] == true ? DEFAULT_LIMIT_SIZE : @options[:limit]
    end
  end
end
