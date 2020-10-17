require 'action_view'
require 'haversine'

class Event < ApplicationRecord
  # Thresholds (in km) for distances to events. We will show events at clubs within the given distance
  LOCAL_DISTANCE = 300
  REGIONAL_DISTANCE = 1000
  NATIONAL_DISTANCE = 2000

  include ActionView::Helpers::SanitizeHelper

  reverse_geocoded_by :lat, :lng

  belongs_to :club
  belongs_to :map
  belongs_to :series
  belongs_to :event_classification
  has_many :organizers
  has_many :courses
  has_one :live_result

  scope :list_includes, -> { includes(:series, :club, :event_classification, :courses) }

  def self.arel_ungeotagged_significant_expr(club)
      local_clubs = club.nearbys(Event::LOCAL_DISTANCE).map { |club| club.id }
      regional_clubs = club.nearbys(Event::REGIONAL_DISTANCE).map { |club| club.id }
      national_clubs = club.nearbys(Event::NATIONAL_DISTANCE).map { |club| club.id }

      arel_table[:lat].eq(nil).
      and(arel_table[:club_id].in(local_clubs)
          .and(arel_table[:event_classification_id].eq(EventClassification::LOCAL_ID))
        .or(arel_table[:club_id].in(regional_clubs)
          .and(arel_table[:event_classification_id].eq(EventClassification::REGIONAL_ID)))
        .or(arel_table[:club_id].in(national_clubs)
          .and(arel_table[:event_classification_id].eq(EventClassification::NATIONAL_ID)))
      )
  end

  # You need this select statement to do the significant event queries
  # Builds a SELECT statement for doing distance based queries.
  #    "#{earth} * 2 * ASIN(SQRT(" +
  #     "POWER(SIN((#{latitude.to_f} - #{lat_attr}) * PI() / 180 / 2), 2) + " +
  #     "COS(#{latitude.to_f} * PI() / 180) * COS(#{lat_attr} * PI() / 180) * " +
  #     "POWER(SIN((#{longitude.to_f} - #{lon_attr}) * PI() / 180 / 2), 2)" +
  #   "))" AS distance
  def self.arel_nearby_select(club)
    arel_distance_expr(club).as('distance')
  end

  def self.arel_distance_expr(club)
    # Converts an expression from degrees to radians
    def self.arel_deg_to_rad(expr)
      pi = Arel::Nodes::NamedFunction.new('PI', [])
      Arel::Nodes::Multiplication.new(expr, Arel::Nodes::Division.new(pi, 180))
    end

    def self.arel_cos_deg(value)
      Arel::Nodes::NamedFunction.new('COS', [arel_deg_to_rad(value)])
    end

    # Builds an expression like: POWER(SIN((#{value} - #{column}) * PI() / 180 / 2), 2)
    def self.arel_pow_sin_expr(value, column)
      delta = Arel::Nodes::Division.new(arel_table.grouping(Arel::Nodes::Subtraction.new(value, column)), 2)
      sin_expr = Arel::Nodes::NamedFunction.new('SIN', [arel_deg_to_rad(delta)])
      Arel::Nodes::NamedFunction.new('POWER', [sin_expr, 2])
    end

    units = Geocoder.config.units
    earth = Arel::Nodes::SqlLiteral.new(Geocoder::Calculations.earth_radius(units).to_s)
    earth_diameter = Arel::Nodes::Multiplication.new(2, earth)
    lat = Arel::Nodes::SqlLiteral.new(club.lat.to_f.to_s)
    lng = Arel::Nodes::SqlLiteral.new(club.lng.to_f.to_s)
    lat_pow_computation = arel_pow_sin_expr(lat, arel_table[:lat])
    lat_cos_computation = Arel::Nodes::Multiplication.new(arel_cos_deg(lat), arel_cos_deg(arel_table[:lat]))
    lng_pow_computation = arel_pow_sin_expr(lng, arel_table[:lng])
    add_computation = Arel::Nodes::Addition.new(lat_pow_computation, Arel::Nodes::Multiplication.new(lat_cos_computation, lng_pow_computation))
    sqrt_computation = Arel::Nodes::NamedFunction.new('SQRT', [add_computation])
    asin_computation = Arel::Nodes::NamedFunction.new('ASIN', [sqrt_computation])
    Arel::Nodes::Multiplication.new(earth_diameter, asin_computation)
  end

  def self.arel_geotagged_significant_expr(club)
    def self.arel_events_of_class_within(classification_id, distance, club)
      # Could do this with a HAVING clause but this seems easier in ActiveRecord
      distance_expr = Arel::Nodes::LessThanOrEqual.new(arel_distance_expr(club), distance)
      arel_table[:event_classification_id].eq(classification_id).and(distance_expr)
    end

    local_events = arel_events_of_class_within(EventClassification::LOCAL_ID, Event::LOCAL_DISTANCE, club)
    regional_events = arel_events_of_class_within(EventClassification::REGIONAL_ID, Event::REGIONAL_DISTANCE, club)
    national_events = arel_events_of_class_within(EventClassification::NATIONAL_ID, Event::NATIONAL_DISTANCE, club)

    local_events.or(regional_events.or(national_events))
  end

  def self.arel_overarching_significant_expr(club)
    arel_table[:event_classification_id].eq(EventClassification::INTERNATIONAL_ID).
      or(arel_table[:event_classification_id].eq(EventClassification::NATIONAL_ID).
        and(arel_table[:club_id].in(club.national_clubs))
      )
  end

  # Builds an expression of events that are significant to a club excluding events organized by that club
  def self.arel_nonclub_significant_expr(club)
    arel_table[:club_id].not_eq(club.id).and(
      arel_ungeotagged_significant_expr(club).
        or(arel_geotagged_significant_expr(club)).
        or(arel_overarching_significant_expr(club))
    )
  end

  # Builds an expression to find club events
  def self.arel_club_expr(club)
    arel_table[:club_id].eq(club.id)
  end

  def self.arel_club_significant_expr(club)
    arel_club_expr(club).and(arel_table[:event_classification_id].lt(EventClassification::CLUB_ID))
  end

  def local_date
    date.in_time_zone(club.timezone)
  end

  def finish_date
    actual_finish_date = read_attribute(:finish_date)
    actual_finish_date ||= date + 1.hour
    return actual_finish_date
  end

  def local_finish_date
    finish_date.in_time_zone(club.timezone)
  end

  def has_location
    self.lat != nil and self.lng != nil
  end

  def address
    require "geocoder"
    geo = Geocoder.search("#{lat},#{lng}")
    if(geo.first != nil)
      return geo.first.address
    end
  end

  def url
    club.clubsite_url("/events/view/" + id.to_s)
  end

  def number_of_participants
  	actual_count = read_attribute(:number_of_participants)
  	if (actual_count.nil?) then
  		courses = Course.where(:event_id => self.id).select(:id)
  		actual_count = Result.where(:course_id => courses).where('status != \'did_not_start\'').count
  	end

  	return actual_count
  end

  def to_ics
    Time.zone = "UTC"
    event = Icalendar::Event.new
    event.start = date.strftime("%Y%m%dT%H%M%S") + "Z"
    event.end = finish_date.strftime("%Y%m%dT%H%M%S") + "Z"
    event.summary = name
    event.description = strip_tags(description)
    if has_location
      event.geo = Icalendar::Geo.new(lat, lng)
      event.location = "#{lat.round(4)},#{lng.round(4)}"
    end
    event.klass = "PUBLIC"
    # TODO-RWP event.created = self.created_at
    # TODO-RWP event.last_modified = self.updated_at
    event.uid = event.url = url
    event
  end

  def display_colour(for_club)
    if for_club.nil?
      # if no club provided, use the series color
      return series.nil? ? '#000000' : series.color
    elsif for_club.id == club.id
      # if club provided and it matches the event club, use series color if possible
      return series.nil? ? '#000000' : series.color
    else
      # otherwise grayscale based on distance
      distance = distance_to(for_club)
      if (distance < 50)
        return '#000000'
      elsif distance >= 50 && distance < 2000
        hex = 0xAA * (distance - 50) / 1950
        scaled_hex = hex.round.to_s(16).rjust(2, '0')
        return '#' + scaled_hex * 3
      else
        return '#' + 'AA' * 3
      end
    end
  end

  def text_colour(colour)
    # Check color format - #RRGGBB or rgba(0,0,0,0)
    if colour.length == 7
      r = Integer(colour[1,2], 16)
      g = Integer(colour[3,2], 16)
      b = Integer(colour[5,2], 16)
    else
      components = colour.gsub(/[rgba() ]/, '').split(',')
      r = Integer(components[0])
      g = Integer(components[1])
      b = Integer(components[2])
    end

    yiq = ((r * 299) + (g * 587) + (b * 114)) / 1000
    return yiq >= 128 ? '#000000' : '#FFFFFF'
  end

  def to_fullcalendar(prefix_acronym, for_club)
    Time.zone = "UTC"
    out = {}
    out[:id] = id
    out[:title] = prefix_acronym ? (club.acronym + ' - ' + name) : name
    out[:start] = date.to_i
    out[:end] = finish_date.to_i
    if event_classification
      out[:event_classification] = {
        :id => event_classification.id,
        :name => event_classification.name
      }
    end
    out[:allDay] = false
    if has_location
      out[:lat] = lat
      out[:lng] = lng
    end
    out[:club] = {
      :id => club.id,
      :acronym => club.acronym
    }
    if not for_club.nil? and for_club.id == club.id
      out[:color] = display_colour(for_club)
      out[:textColor] = text_colour(out[:color])
    else
      out[:color] = '#FFFFFF'
      out[:textColor] = display_colour(for_club)
    end
    out[:url] = url
    unless for_club.nil?
      distance = distance_to(for_club)
      if (distance > 100)
        out[:title] += " (" + distance.round(-1).to_s + "km)"
      end
    end
    out
  end

  # in km
  def distance_to(other_club)
    if has_location
      return Haversine.distance(lat, lng, other_club.lat, other_club.lng)
    else
      return Haversine.distance(club.lat, club.lng, other_club.lat, other_club.lng)
    end
  end

  def has_organizer?(user)
    Organizer.where(user_id: user.id, event_id: self.id).exists?
  end
end
