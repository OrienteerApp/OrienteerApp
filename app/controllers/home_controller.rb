class HomeController < ApplicationController
  def about_whyjustrun
    @primary_whyjustrun_clubs = Club.primary_whyjustrun_clubs
    logger.error @primary_whyjustrun_clubs.length
  end

  def about_orienteering
    @top_level_clubs = Club.all_top_level.where(:visible => true)
  end
end
