class AddRegistrationDeadlineToEvents < ActiveRecord::Migration[4.2]
  def change
    add_column :events, :registration_deadline, :datetime
  end
end
