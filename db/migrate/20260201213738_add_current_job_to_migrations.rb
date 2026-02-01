class AddCurrentJobToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :current_job_step, :string
    add_column :migrations, :current_job_attempt, :integer, default: 0
    add_column :migrations, :current_job_max_attempts, :integer, default: 3
  end
end
