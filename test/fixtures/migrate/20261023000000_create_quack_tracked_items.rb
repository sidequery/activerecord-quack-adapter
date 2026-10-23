class CreateQuackTrackedItems < ActiveRecord::Migration[7.2]
  def change
    create_table(:quack_tracked_items) { |table| table.string :name }
  end
end
