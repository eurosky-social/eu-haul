class CreateLegalSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :legal_snapshots do |t|
      t.string :document_type, null: false
      t.string :content_hash, null: false
      t.text :rendered_content, null: false
      t.string :version_label, null: false
      t.timestamps
    end

    add_index :legal_snapshots, [:document_type, :content_hash], unique: true
    add_index :legal_snapshots, [:document_type, :created_at]
  end
end
