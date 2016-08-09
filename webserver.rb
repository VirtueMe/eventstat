# encoding: utf-8

require 'rubygems'
require 'bundler/setup'

require 'sinatra'
require 'sinatra/flash'
require "sinatra/reloader" if development?
require 'tilt/erb' if development?

require 'date'

require_relative 'models'
require_relative 'settings'

ActiveRecord::Base.establish_connection(Settings::DBWEB)

register Sinatra::Reloader if development?
set :bind, '0.0.0.0' if development?
set :port, 5100 if development?
enable :show_exceptions if development?

set :server, %w[thin webrick]
set :sessions, key: Settings::SESSION_KEY, secret: Settings::SECRET


# -------------------------

def require_logged_in
  redirect('/login') unless is_authenticated?
end

def is_authenticated?
  return session[:user_id]
end

def is_admin?
  session[:admin]
end

def protected!
  halt 401, "You are not authorized to see this page!" unless admin?
end

# -------------------------


get '/' do
  redirect('/manage_events')
end

get '/login' do
  erb :login
end

get '/logout' do
  session.clear
  redirect('/')
end


post '/sessions' do
  if params[:password] == Settings::PW
    session[:user_id] = params[:username]
  end

  if params["pw"] == Settings::PWADMIN
    session[:user_id] = params["user_id"]
    session[:admin] = params["user_id"]
  end

  session.options[:expire_after] = 60*60*24*60 if session[:user_id].present? && params[:remember].present?

  redirect('/')
end

get '/manage_events' do
  require_logged_in

  error = session[:transaction_error] == true
  session[:transaction_error] = nil

  erb :manage_events, :locals => {branches: Branch.all, subcategories: Subcategory.all,
    age_groups: AgeGroup.all, edit: false, error: error }
  end


  get '/view_events' do
    require_logged_in

    success = session[:transaction_success] == true
    session[:transaction_success] = nil

    erb :view_events, :locals => {events: Event.all, branches: Branch.all, success: success}
  end


  get '/edit_event/:event_id' do
    require_logged_in

    event_id = params['event_id']

    erb :manage_events, :locals => {branches: Branch.all, subcategories: Subcategory.all,
      agegroups: AgeGroup.all, event: Event.find(event_id), edit: true, error: false }
    end


    get '/view_statistics' do
      require_logged_in

      error = session[:transaction_error] == true
      session[:transaction_error] = nil

      erb :statistics, :locals => {branches: Branch.all, subcategories: Subcategory.all,
        categories: Category.all, age_groups: AgeGroup.all}
    end

    get '/enable_javascript' do
      erb :enable_javascript
    end


    # CRUDS

    post '/api/event' do
      require_logged_in

      data = JSON.parse(request.body.read)
      event_data = data['event_data']
      count_data = data['count_data']

      is_edit = event_data['id'].present?
      event_id = event_data['id'].to_i if is_edit

      event = is_edit ? Event.find(event_id) : Event.new
      event.attributes = event.attributes.merge(event_data) {|key, oldVal, newVal| key == 'id' ? oldVal : newVal}

      success = false

      ActiveRecord::Base.transaction do
        event.save!

        if is_edit
          old_counts = Count.where('event_id = ?', event_id)
          old_counts.each do |ct|
            ct.destroy!
          end
        end

        count_data.each do |age_group_id, attendants|
          count = Count.new do |ct|
            ct.event_id = event.id
            ct.age_group_id = age_group_id
            ct.attendants = attendants
          end
          count.save!
        end

        success = true
      end

      success = false # todo håndter feilmelding

      if success
        session[:transaction_success] = true
        {redirect: '/view_events'}.to_json

      else
        session[:transaction_error] = true
        {redirect: '/edit_event/' + event.id.to_s}.to_json
      end
    end


    put '/api/statistics' do
      data = JSON.parse(request.body.read)
      branch_id = data["branch_id"]
      category_id = data["category_id"]
      subcategory_id = data["subcategory_id"]
      @from_date = Date.parse(data["from_date"])
      @to_date = Date.parse(data["to_date"])


      sum_all_branches = branch_id == 'sum_all'
      branches = branch_id == 'iterate_all' ? Branch.all : Branch.where(id: branch_id)

      sum_all_categories = category_id == 'sum_all' || subcategory_id == 'sum_all'
      @iterate_over_categories = category_id != 'none'

      results = []

      if sum_all_branches && sum_all_categories
        events = get_events
        results << calculate_result('Samlet', events, events.size())
      elsif sum_all_branches # implicit iterate categories
        results << iterate_subcategories(nil, 'Samlet')
      else       # implicit iterate_branches
        branches.each do |branch|
          if sum_all_categories
            events = get_events(branch.id)
            results << calculate_result(branch.name, events, events.size())
          else
            results << iterate_subcategories(branch.id, branch.name)
          end
        end
      end

        {results: results.flatten}.to_json
      end

      #TODO BIG FIX
    def iterate_subcategories(branch_id, branch_name)
      results = []

      cats = @iterate_over_categories ? Category.all : Subcategory.all
      cats.each do |cat|
        events = @iterate_over_categories ? get_events(branch_id, cat.id, nil) : get_events(branch_id, nil, cat.id)
        results << calculate_result(branch_name, events, events.size())
      end
      results
    end


    def get_events (branch_id = nil, category_id = nil, subcategory_id = nil)
      Event.between_dates(@from_date, @to_date)
        .by_branch(branch_id)
        .by_category(category_id)
        .by_subcategory(subcategory_id)
    end


    def calculate_result(branch_name, events, size)
      young_ages_count = events.to_a.sum(&:sum_young_ages)
      all_ages_count = events.to_a.sum(&:sum_all_ages)

      {branch_name: branch_name, all: all_ages_count, young: young_ages_count, no_of_events: events.size()}
    end

    # needed when using the Sinatra::Reloader to avoid draining the connection pool
    after do
      ActiveRecord::Base.clear_active_connections!
    end
