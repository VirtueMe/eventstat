# encoding: utf-8
require 'csv'


# Filter:
# collection - activerecord collection
# sum_all - boolean flag, if set to false then the collection will be iterated over
# sum_multipe_as_one: fucked if I know
Filter = Struct.new(:collection, :sum_all, :sum_multiple_as_one)

# LineItem:
# Used during filter traversal to generate labels for the table columns
LineItem = Struct.new(:id, :label)

# HeaderItem:
# Simple struct for generating the table headers
#
# :label - for the table headers
# :id - marker for matching table data with the correct column
# :is_countable - boolean flag indicating whether the column values should be accumulated
HeaderItem = Struct.new(:label, :id, :is_countable)


module Mod

  def Mod.create_filter(id, klazz)
    id = parse_value(id)
    sum_all = id == 'sum_all'
    collection = id == 'iterate_all' ? klazz.all : klazz.where(id: id)
    Filter.new(collection, sum_all)
  end


  def Mod.parse_value(input)
    %w(iterate_all sum_all none).include?(input) ? input : input.split(',')
  end

  def get_compound_results
    compound_query = CompoundQuery.find(@compound_query_id)

    queries = compound_query.queries.map do |query|
      query_map = {}
      query.query_parameters.each {|parameter| query_map[parameter.element_name.to_sym] = parse_value(parameter.element_value)}
      query_map
    end
  end

end


#
# ReportBuilder
#
# Setters for defining the filters for the final report.
#
# Parameters: The id parameters can have the following values:
# 'iterate_all' - report will iterate over all existing items (one lite item for each)
# 'sum_all' - all existing items will be lumped as one
# 'none' - for mutually exclusive categories...
# single id or list of id values



class BetaReport
  include Mod
  attr_accessor :headers, :queries

  def initialize(args)
    @headers = build_headers


    static_keys = %i(period_label from_date to_date branch_id)
    static_arguments = args.select {|key| static_keys.include?(key)}
    q = Q.new(static_arguments)


    dynamic_keys = %i(maintype_id subtype_id category_id subcategory_id district_category_id
     age_group_id age_category_id use_district_categories expand_district_subcategories)
    dynamic_arguments = args.select {|key| dynamic_keys.include?(key)}
    @queries = [Subquery.new(q, @headers, dynamic_arguments)]


    if args[:compound_query_id].present?
      compound_query = CompoundQuery.find(args[:compound_query_id])

      query_list = compound_query.queries.map do |query|
        query_map = {}
        query.query_parameters.each {|parameter| query_map[parameter.element_name.to_sym] = Mod.parse_value(parameter.element_value)}
        query_map
      end

      @queries = []
      query_list.each do |query|
        @queries << Subquery.new(q, @headers, query)
      end

    end


  end

  def get_results
    #puts @queries.inspect
    #@queries.get_single_results
    compound_results = []
    @queries.each do |query|
      #puts query.inspect
      compound_results << query.get_single_results
    end

    #compound_results << @results.flatten

    compound_results.flatten!
    compound_results.sort! {|x,y| x[:branch_name] <=> y[:branch_name] }

    {headers: @headers.flatten, results: compound_results.flatten}.to_json
  end


  def build_headers
    headers = []

    # fixed headers
    headers << HeaderItem.new("Periode", "period", false)
    headers << HeaderItem.new("Sted", "branch_name", false)

    # dynamic headers
    headers << HeaderItem.new("Type", "maintype", false)
    headers << HeaderItem.new("Undertype", "subtype", false)
    headers << HeaderItem.new("Kategori", "category", false)
    headers << HeaderItem.new("Underkategori", "subcategory", false)
    headers << HeaderItem.new("Alder", "agecategory", false)
    headers << HeaderItem.new("Alder", "agegroup", false)

    # fixed, countable headers
    headers << HeaderItem.new("Ant. arr", "no_of_events", true)
    headers << HeaderItem.new("Ant. deltagere", "no_of_attendants", true)

    headers.flatten
  end

end



class Q
  include Mod

  attr_accessor :period_label, :from_date, :to_date, :branches, :categories, :subcategories,
    :use_district_categories, :category_type, :maintypes, :subtypes, :age_groups,
    :age_categories, :headers, :include_district_subcategories, :header_type, :report_type,
    :compound_query_id

  # TODO validate methods?
  def initialize(args)
    @from_date = Date.parse(args[:from_date])
    @to_date = Date.parse(args[:to_date])
    @period_label = args[:period_label]

    branch_id = args[:branch_id]
    @branches = Mod.create_filter(branch_id, Branch)

    # TODO this only works as long as there is only one set of district subcategories
    # a better solution would figure out which district subcategories should be included
    @include_district_subcategories = %w(sum_all iterate_all).include?(branch_id) || Branch.where(id: branch_id).where(has_district_category: 1).count > 0
  end

end

# results should have: headers, data, template
# use one standard header, and set template data

class Subquery
  include Mod

  # attr_accessor :fixed, :dynamic
  attr_accessor :category_type, :categories, :maintypes, :subtypes, :age_groups, :results, :q, :headers

  def initialize(q, headers, args)
    puts "xxxx"
    puts args.inspect
    puts "xxxx"
    puts args[:maintype_id]
    puts "yyyyy"

    @q = q
    @headers = headers
    @maintypes = Mod.create_filter(args[:maintype_id], EventMaintype)
    @subtypes = Mod.create_filter(args[:subtype_id], EventSubtype)

    # handle categories
    if args[:category_id].present? && args[:category_id] != 'none'
      set_category(args[:category_id], args[:use_district_categories].present?)
    elsif args[:subcategory_id].present? && args[:subcategory_id] != 'none'
      set_subcategory(args[:subcategory_id], args[:expand_district_subcategories].present?)
    else
      # raise error?
    end

    # handle ages
    set_age_group(args[:age_group_id], args[:age_category_id]) # TODO fix this
  end

  def set_category(arg, use_district_categories)
    @category_type = :category

    klazz = use_district_categories ? DistrictCategory : Category
    @categories = Mod.create_filter(arg, klazz)
  end

  def set_subcategory(arg, expand_district_subcategories)
    subcategory_id = parse_value(arg)
    @report.category_type = :subcategory

    if @q.include_district_subcategories && expand_district_subcategories
      subcategories = subcategory_id == 'iterate_all' ?
        Subcategory.expanded : Subcategory.where(id: subcategory_id)
    elsif @q.include_district_subcategories
      subcategories = subcategory_id == 'iterate_all' ? Subcategory.compacted : Subcategory.where(id: subcategory_id)
    else
      subcategories = subcategory_id == 'iterate_all' ? InternalSubcategory.all : InternalSubcategory.where(id: subcategory_id)
    end

    sum_all = subcategory_id == 'sum_all'
    @categories = Filter.new(subcategories, sum_all)
  end
  #------------------------

  # special case. needs better, less fugly solution. but works for now
  def set_age_group(age_group_id, age_category_id)
    sum_all = age_group_id == 'sum_all' || age_category_id == 'sum_all'
    sum_multiple_as_one = false

    if age_category_id == 'none'
      categories = []
      age_groups = age_group_id == 'iterate_all' ? AgeGroup.all : AgeGroup.where(id: age_group_id)
      age_groups.each do |ag|
        categories << LineItem.new(ag.id, ag.name)
      end
    elsif age_category_id == 'iterate_all'
      categories = []
      AgeGroup.age_categories.each do |ag|
        label = AgeGroup.get_label(ag[0])
        id = AgeGroup.where(age_category: ag[1])
        categories << LineItem.new(id, label)
      end
    else
      label =  AgeGroup.get_label(age_category_id)
      id = AgeGroup.where(age_category: age_category_id)
      categories = LineItem.new(id, label)
      sum_multiple_as_one = true
    end

    @age_groups = Filter.new(categories, sum_all, sum_multiple_as_one)
  end


  # --------------------

  def extract_headers
    headers = []
    headers << HeaderItem.new("Type", "maintype", false) unless @subquery[:maintype_id] == 'sum_all'
    headers << HeaderItem.new("Undertype", "subtype", false) unless @subquery[:subtype_id] == 'sum_all'
    headers << HeaderItem.new("Kategori", "category", false) unless @subquery[:category_id].blank? || @subquery[:category_id] == 'sum_all'
    headers << HeaderItem.new("Underkategori", "subcategory", false) unless @subquery[:subcategory_id].blank? || @subquery[:subcategory_id] == 'sum_all'
    headers << HeaderItem.new("Alder", "agecategory", false) unless @subquery[:age_category_id].blank? || @subquery[:age_category_id] == 'sum_all'
    headers << HeaderItem.new("Alder", "agegroup", false) unless @subquery[:age_group_id].blank? || @subquery[:age_group_id] == 'sum_all'

    headers.flatten
  end


  #
  # -------------------
  #

  def get_single_results
    @results = []
    traverse_branches

    #{headers: @headers.flatten, results: @results.flatten}
    @results.flatten
  end

  def traverse_branches
    if @q.branches.sum_all
      traverse_maintypes(LineItem.new(nil, 'Samlet'))
    else
      @q.branches.collection.each do |branch|
        traverse_maintypes(LineItem.new(branch.id, branch.name))
      end
    end
  end

  def traverse_maintypes(branch)
    if @maintypes.sum_all
      traverse_subtypes(branch, LineItem.new(nil, 'Samlet'))
    else
      @maintypes.collection.each do |maintype|
        traverse_subtypes(branch, LineItem.new(maintype.id, maintype.label))
      end
    end
  end


  def traverse_subtypes(branch, maintype)
    if @subtypes.sum_all
      traverse_age_groups(branch, maintype, LineItem.new(nil, 'Samlet'))
    else
      @subtypes.collection.each do |subtype|
        next unless maintype.id == nil || subtype.associated?(maintype.id)

        traverse_age_groups(branch, maintype, LineItem.new(subtype.id, subtype.label))
      end
    end
  end

  def traverse_age_groups(branch, maintype, subtype)
    if @age_groups.sum_all
      traverse_categories(branch, maintype, subtype, LineItem.new(nil, 'Samlet'))
    elsif @age_groups.sum_multiple_as_one
      traverse_categories(branch, maintype, subtype, @age_groups.collection)
    else
      @age_groups.collection.each do |ag|
        traverse_categories(branch, maintype, subtype, ag)
      end
    end
  end


  def traverse_categories(branch, maintype, subtype, age_group)
    if @categories.sum_all
      events = get_events(branch.id, subtype_id: subtype.id, maintype_id: maintype.id, age_group_id: age_group.id)
      calculate_result(branch_name: branch.label, events: events, subtype: subtype.label, maintype: maintype.label, age_group: age_group.label)
    else @categories.collection.each do |cat|
      next unless cat.subtype_associated?(subtype.id) ||
      cat.maintype_associated?(maintype.id) ||(subtype.id.nil? && maintype.id.nil?)

      events = case @category_type
      when :category then get_events(branch.id, category_id: cat.id, subtype_id: subtype.id, maintype_id: maintype.id, age_group_id: age_group.id)
      when :subcategory then get_events(branch.id, subcategory_id: cat.id, subtype_id: subtype.id, maintype_id: maintype.id, age_group_id: age_group.id)
      end

      calculate_result(branch_name: branch.label, category_name: cat.name, events: events, subtype: subtype.label, maintype: maintype.label, age_group: age_group.label)
    end
  end
end


  # return value = {}
  def calculate_result(branch_name: 'Samlet', category_name: 'Samlet', events: nil,
    maintype: 'Samlet', subtype: 'Samlet', age_group: 'Samlet')

    young_ages_count = events.to_a.sum(&:sum_non_adults)
    all_ages_count = events.to_a.sum(&:sum_all_ages)
    older_ages_count = events.to_a.sum(&:sum_adults)

    # legg til events.non_adults.size
    # legg til header "Arr for barn/unge"
    # ny set metode include_subsize(truefalse)
    res = {}
    @headers.each do |header|
      res[header.id.to_sym] = @q.period_label if header.id == "period"
      res[header.id.to_sym] = branch_name if header.id == "branch_name"
      res[header.id.to_sym] = category_name if header.id == "category"
      res[header.id.to_sym] = category_name if header.id == "subcategory"
      res[header.id.to_sym] = maintype if header.id == "maintype"
      res[header.id.to_sym] = subtype if header.id == "subtype"
      res[header.id.to_sym] = age_group if header.id == "age_group"
      res[header.id.to_sym] = events.size if header.id == "no_of_events"
      res[header.id.to_sym] = all_ages_count if header.id == "no_of_attendants"
      res[header.id.to_sym] = age_group if header.id == "agegroup"
      # add more
    end

    #res[:link] = {from_date: @from_date, to_date: @to_date, label: @period_label, }
    # maybe better? :
    ##res[:link] = {this_query.to_json}


    @results << res
  end


  def get_events (branch_id = nil, category_id: nil, subcategory_id: nil, district_category_id: nil,
    maintype_id: nil, subtype_id: nil, age_group_id: nil)

    catz = @use_district_categories ? 'by_district_category' : 'by_category'

    Event.between_dates(@q.from_date, @q.to_date)
    .exclude_marked_events
    .by_branch(branch_id)
    .by_age_group(age_group_id)
    .by_maintype(maintype_id)
    .by_subtype(subtype_id)
    .by_subcategory(subcategory_id, @expand_district_subcategories)
    .send(catz, category_id)
  end



  # -----

end



# scratch this?
class Header
  def init(items)
    headers = []

    # fixed headers
    headers << HeaderItem.new("Periode", "period", false)
    headers << HeaderItem.new("Sted", "branch_name", false)

    # fixed, countable headers
    headers << HeaderItem.new("Ant. arr", "no_of_events", true)
    headers << HeaderItem.new("Ant. deltagere", "no_of_attendants", true)

    headers.flatten
  end
end




class ReportBuilder
  def initialize
    @report = Report.new
  end

  def report
    obj = @report.dup
    @report = Report.new
    return obj
  end

  def build
    @report.report_type ||= :single
    @report.header_type ||= :dynamic
    @report.headers = build_headers
    return report
  end

  def build_headers
    is_dynamic = @report.header_type == :dynamic

    headers = []

    # fixed headers
    headers << HeaderItem.new("Periode", "period", false)
    headers << HeaderItem.new("Sted", "branch_name", false)

    # dynamic headers
    headers << HeaderItem.new("Type", "maintype", false) unless is_dynamic && @report.maintypes.sum_all
    headers << HeaderItem.new("Undertype", "subtype", false) unless is_dynamic && @report.subtypes.sum_all
    headers << HeaderItem.new("Kategori", "category", false) unless is_dynamic && (@report.categories.nil? || @report.categories.sum_all) #|| @report.category_type == :subcategory
    headers << HeaderItem.new("Underkategori", "subcategory", false) unless is_dynamic && (@report.subcategories.nil? || @report.subcategories.sum_all) #|| @report.category_type == :category
    headers << HeaderItem.new("Alder", "agecategory", false) unless true && (@report.age_categories.nil? || @report.age_categories.sum_all)
    headers << HeaderItem.new("Alder", "agegroup", false) unless true && (@report.age_groups.nil? || @report.age_groups.sum_all)

    # fixed, countable headers
    headers << HeaderItem.new("Ant. arr", "no_of_events", true)
    headers << HeaderItem.new("Ant. deltagere", "no_of_attendants", true)


    headers.flatten
  end


  def create_filter(id, klazz)
    sum_all = id == 'sum_all'
    collection = id == 'iterate_all' ? klazz.all : klazz.where(id: id)
    Filter.new(collection, sum_all)
  end

  #
  # Setters
  #


  def set_compound_query(id)
    @report.report_type = :compound
    @report.compound_query_id = id
  end

  def set_strategy(key)
    @report.strategy = key
  end

  def set_period_label(str)
    @report.period_label = str
  end

  def set_dates(from_date, to_date)
    @report.from_date = from_date
    @report.to_date = to_date
  end


  # TODO this only works as long as there is only one set of district subcategories
  # a better solution would figure out which district subcategories should be included
  def set_branch(branch_id)
    @report.include_district_subcategories = ['sum_all', 'iterate_all'].include?(branch_id) || Branch.where(id: branch_id).where(has_district_category: 1).count > 0

    @report.branches = create_filter(branch_id, Branch)
    self
  end


  def set_category(category_id, use_district_categories)
    @report.category_type = :category
    @report.use_district_categories = use_district_categories

    klazz = use_district_categories ? DistrictCategory : Category

    @report.categories = create_filter(category_id, klazz)
  end


  # TODO this presupposes that @report.include_district_subcategories has already been set
  def set_subcategory(subcategory_id, expand_district_subcategories)
    @report.category_type = :subcategory

    if @report.include_district_subcategories and expand_district_subcategories
      subcategories = subcategory_id == 'iterate_all' ?
        Subcategory.expanded : Subcategory.where(id: subcategory_id)
    elsif @report.include_district_subcategories
      subcategories = subcategory_id == 'iterate_all' ? Subcategory.compacted : Subcategory.where(id: subcategory_id)
    else
      subcategories = subcategory_id == 'iterate_all' ? InternalSubcategory.all : InternalSubcategory.where(id: subcategory_id)
    end

    sum_all = subcategory_id == 'sum_all'
    @report.categories = Filter.new(subcategories, sum_all)
  end


  def set_maintype(maintype_id)
    @report.maintypes = create_filter(maintype_id, EventMaintype)
  end

  def set_subtype(subtype_id)
    @report.subtypes = create_filter(subtype_id, EventSubtype)
  end


  # special case. needs better, less fugly solution. but works for now
  def set_age_group(age_group_id, age_category_id)
    sum_all = age_group_id == 'sum_all' || age_category_id == 'sum_all'
    sum_multiple_as_one = nil

    if age_category_id == 'none'
      categories = []
      age_groups = age_group_id == 'iterate_all' ? AgeGroup.all : AgeGroup.where(id: age_group_id)
      age_groups.each do |ag|
        categories << LineItem.new(ag.id, ag.name)
      end
    elsif age_category_id == 'iterate_all'
      categories = []
      AgeGroup.age_categories.each do |ag|
        label = AgeGroup.get_label(ag[0])
        id = AgeGroup.where(age_category: ag[1])
        categories << LineItem.new(id, label)
      end
    else
      #categories = age_category_id == 'iterate_all' ? AgeGroup.age_categories : AgeGroup.where(age_category: age_category_id)
      label =  AgeGroup.get_label(age_category_id)
      id = AgeGroup.where(age_category: age_category_id)
      categories = LineItem.new(id, label)
      sum_multiple_as_one = true
    end

    @report.age_groups = Filter.new(categories, sum_all, sum_multiple_as_one)
  end
end


#
# Aggregate report
#
# Each report consists of a headers object and a results object
# If the headers are set to static, the results object will always have the same fields
#
# For compound queries, you want the sort the results per branch
# Adding a branch_id key or branch code key would be good for this
# Possible strategy I: Run each query in succession, store the results and then sort them by branch code/id
#
# Setup will be: query, and aggregate queries ()
#
#mysql> describe queries;
#+----------+--------------+------+-----+---------+----------------+
#| Field    | Type         | Null | Key | Default | Extra          |
#+----------+--------------+------+-----+---------+----------------+
#| id       | int(11)      | NO   | PRI | NULL    | auto_increment |
#| name     | varchar(255) | NO   |     | NULL    |                |
#| type     | varchar(255) | YES  |     | Query   |                |
#| query_id | int(11)      | YES  |     | NULL    |                |
#+----------+--------------+------+-----+---------+----------------+

# where type is either subquery or compound_query



#
# Report
#

class Report
  attr_accessor :period_label, :from_date, :to_date, :branches, :categories, :subcategories,
    :use_district_categories, :category_type, :maintypes, :subtypes, :age_groups,
    :age_categories, :headers, :strategy, :include_district_subcategories, :header_type, :report_type,
    :compound_query_id

  # TODO validate methods?

  # helpers - TODO move to module

  def create_filter(id, klazz)
    sum_all = id == 'sum_all'
    collection = id == 'iterate_all' ? klazz.all : klazz.where(id: id)
    Filter.new(collection, sum_all)
  end

  def build_headers
    is_dynamic = @header_type == :dynamic

    headers = []

    # fixed headers
    headers << HeaderItem.new("Periode", "period", false)
    headers << HeaderItem.new("Sted", "branch_name", false)

    # dynamic headers
    headers << HeaderItem.new("Type", "maintype", false) unless is_dynamic && @maintypes.sum_all
    headers << HeaderItem.new("Undertype", "subtype", false) unless is_dynamic && @subtypes.sum_all
    headers << HeaderItem.new("Kategori", "category", false) unless is_dynamic && (@categories.nil? || @categories.sum_all) #|| @report.category_type == :subcategory
    headers << HeaderItem.new("Underkategori", "subcategory", false) unless is_dynamic && (@subcategories.nil? || @subcategories.sum_all) #|| @report.category_type == :category
    headers << HeaderItem.new("Alder", "agecategory", false) unless true && (@age_categories.nil? || @age_categories.sum_all)
    headers << HeaderItem.new("Alder", "agegroup", false) unless true && (@age_groups.nil? || @age_groups.sum_all)

    # fixed, countable headers
    headers << HeaderItem.new("Ant. arr", "no_of_events", true)
    headers << HeaderItem.new("Ant. deltagere", "no_of_attendants", true)

    headers.flatten
  end


  # business


  def get_results
    @report_type == :compound ? get_compound_results : get_single_results
  end

  # for each query, only type, category and age will vary - all else remains stable
  # but - should age vary?

  def parse_value(input)
    %w(iterate_all sum_all none).include?(input) ? input : input.split(',')
  end

  def get_compound_results
    compound_query = CompoundQuery.find(@compound_query_id)

    queries = compound_query.queries.map do |query|
      query_map = {}
      query.query_parameters.each {|parameter| query_map[parameter.element_name.to_sym] = parse_value(parameter.element_value)}
      query_map
    end

    @header_type == compound_query.use_static_headers ? :static : :dynamic
    @headers = build_headers if compound_query.use_static_headers
    build_headers_once = !compound_query.use_static_headers

    compound_results = []
    queries.each do |query|
      @maintypes = create_filter(query[:event_maintype_id], EventMaintype)
      @subtypes = create_filter(query[:event_subtype_id], EventSubtype)


      if query[:category_id] != 'none'
        @category_type = :category
        #use_district_categories = use_district_categories
        #klazz = use_district_categories ? DistrictCategory : Category
        @categories = create_filter(query[:category_id], Category)
      else
        @category_type = :subcategory
        @subcategories = query[:subcategory_id] == 'iterate_all' ? Subcategory.compacted : Subcategory.where(id: subcategory_id)
        @categories = create_filter(query[:subcategory_id], Subcategory.compacted)
      end

      sum_all = query[:age_group_id] == 'sum_all' || query[:age_category_id] == 'sum_all'
      sum_multiple_as_one = query[:age_group_id] != 'none'

      if query[:age_category_id] == 'none'
        categories = []
        age_groups = query[:age_group_id] == 'iterate_all' ? AgeGroup.all : AgeGroup.where(id: query[:age_group_id])
        age_groups.each do |ag|
          categories << LineItem.new(ag.id, ag.name)
        end
      elsif query[:age_category_id] == 'iterate_all'
        categories = []
        AgeGroup.age_categories.each do |ag|
          label = AgeGroup.get_label(ag[0])
          id = AgeGroup.where(age_category: ag[1])
          categories << LineItem.new(id, label)
        end
      else
        label =  AgeGroup.get_label(query[:age_category_id])
        id = AgeGroup.where(age_category: query[:age_category_id])
        categories = LineItem.new(id, label)
      end

      @age_groups = Filter.new(categories, sum_all, sum_multiple_as_one)

      # only build headers once...
      if build_headers_once
        @headers = build_headers
        build_headers_once = false
      end

      @results = []
      traverse_branches
      compound_results << @results.flatten
    end

    compound_results.flatten!
    compound_results.sort! {|x,y| x[:branch_name] <=> y[:branch_name] }

    {headers: @headers.flatten, results: compound_results.flatten}.to_json
  end

  def get_single_results
    @results = []
    traverse_branches

    {headers: @headers.flatten, results: @results.flatten}.to_json
  end

  def traverse_branches
    if @branches.sum_all
      traverse_maintypes(LineItem.new(nil, 'Samlet'))
    else
      @branches.collection.each do |branch|
        traverse_maintypes(LineItem.new(branch.id, branch.name))
      end
    end
  end

  def traverse_maintypes(branch)
    if @maintypes.sum_all
      traverse_subtypes(branch, LineItem.new(nil, 'Samlet'))
    else
      @maintypes.collection.each do |maintype|
        traverse_subtypes(branch, LineItem.new(maintype.id, maintype.label))
      end
    end
  end


  def traverse_subtypes(branch, maintype)
    if @subtypes.sum_all
      traverse_age_groups(branch, maintype, LineItem.new(nil, 'Samlet'))
    else
      @subtypes.collection.each do |subtype|
        next unless maintype.id == nil || subtype.associated?(maintype.id)

        traverse_age_groups(branch, maintype, LineItem.new(subtype.id, subtype.label))
      end
    end
  end

  def traverse_age_groups(branch, maintype, subtype)
    if @age_groups.sum_all
      traverse_categories(branch, maintype, subtype, LineItem.new(nil, 'Samlet'))
    elsif @age_groups.sum_multiple_as_one
      traverse_categories(branch, maintype, subtype, @age_groups.collection)
    else
      @age_groups.collection.each do |ag|
        traverse_categories(branch, maintype, subtype, ag)
      end
    end
  end


  def traverse_categories(branch, maintype, subtype, age_group)
    if @categories.sum_all
      events = get_events(branch.id, subtype_id: subtype.id, maintype_id: maintype.id, age_group_id: age_group.id)
      calculate_result(branch_name: branch.label, events: events, subtype: subtype.label, maintype: maintype.label, age_group: age_group.label)
    else @categories.collection.each do |cat|
      next unless cat.subtype_associated?(subtype.id) ||
      cat.maintype_associated?(maintype.id) ||(subtype.id.nil? && maintype.id.nil?)

      events = case @category_type
      when :category then get_events(branch.id, category_id: cat.id, subtype_id: subtype.id, maintype_id: maintype.id, age_group_id: age_group.id)
      when :subcategory then get_events(branch.id, subcategory_id: cat.id, subtype_id: subtype.id, maintype_id: maintype.id, age_group_id: age_group.id)
      end

      calculate_result(branch_name: branch.label, category_name: cat.name, events: events, subtype: subtype.label, maintype: maintype.label, age_group: age_group.label)
    end
  end
end


  # return value = {}
  def calculate_result(branch_name: 'Samlet', category_name: 'Samlet', events: nil,
    maintype: 'Samlet', subtype: 'Samlet', age_group: 'Samlet')

    young_ages_count = events.to_a.sum(&:sum_non_adults)
    all_ages_count = events.to_a.sum(&:sum_all_ages)
    older_ages_count = events.to_a.sum(&:sum_adults)

    # legg til events.non_adults.size
    # legg til header "Arr for barn/unge"
    # ny set metode include_subsize(truefalse)
    res = {}
    @headers.each do |header|
      res[header.id.to_sym] = @period_label if header.id == "period"
      res[header.id.to_sym] = branch_name if header.id == "branch_name"
      res[header.id.to_sym] = category_name if header.id == "category"
      res[header.id.to_sym] = category_name if header.id == "subcategory"
      res[header.id.to_sym] = maintype if header.id == "maintype"
      res[header.id.to_sym] = subtype if header.id == "subtype"
      res[header.id.to_sym] = age_group if header.id == "age_group"
      res[header.id.to_sym] = events.size if header.id == "no_of_events"
      res[header.id.to_sym] = all_ages_count if header.id == "no_of_attendants"
      res[header.id.to_sym] = age_group if header.id == "agegroup"
      # add more
    end

    #es[:link] = {from_date: @from_date, to_date: @to_date, label: @period_label, }


    @results << res
  end


  def get_events (branch_id = nil, category_id: nil, subcategory_id: nil, district_category_id: nil,
    maintype_id: nil, subtype_id: nil, age_group_id: nil)

    catz = @use_district_categories ? 'by_district_category' : 'by_category'

    Event.between_dates(@from_date, @to_date)
    .exclude_marked_events
    .by_branch(branch_id)
    .by_age_group(age_group_id)
    .by_maintype(maintype_id)
    .by_subtype(subtype_id)
    .by_subcategory(subcategory_id, @expand_district_subcategories)
    .send(catz, category_id)
  end
end
