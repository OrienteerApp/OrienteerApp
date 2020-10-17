class ClubsController < ApplicationController
  def index
    @clubs = Club.where(:visible => true).includes(:club_category)
    respond_to do |format|
      format.xml  { render :layout => false }
    end
  end

  # provides a CSV file with participant counts for the club events and any child club events
  def participant_counts
  	respond_to do |format|
  		format.csv { render :layout => false }
  	end
  end

  def map
    @clubs = Club.all_leaves.where(:visible => true)
  end

  def events
    @events = Event.limit(50).where("club_id = ?", params[:id]).order('date DESC')

    respond_to do |wants|
      wants.ics do
        calendar = Icalendar::Calendar.new
        calendar.x_wr_calname = Club.find(club_id).name
        @events.each { |event|
          calendar.add_event(event.to_ics)
        }
        calendar.publish
        render :plain => calendar.to_ical
      end
    end
  end
end
