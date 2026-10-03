module Admin
  # What the household's agents keep (RECORDS.md), for the people who decide
  # it: every collection, live or retracted, and the records a person took
  # away. Restoring brings a collection or a record back whole; purging
  # removes it for good, and is the only way anything here is removed. Only
  # what was retracted first can be purged.
  class RecordsController < BaseController
    def index
      @collections = RecordCollection.includes(:principal, :proposed_by, :retracted_by).order(:name)
      @counts = Record.live.group(:collection_id).count
      @last = Record.live.group(:collection_id).maximum(:updated_at)
      @retracted = Record.where.not(retracted_at: nil).includes(:collection).order(retracted_at: :desc).limit(50)
    end

    def show
      @collection = RecordCollection.find_by!(name: params[:name])
      @records = @collection.records.live.includes(:written_by).order(updated_at: :desc).limit(50)
      @count = @collection.records.live.count
      @retracted = @collection.records.where.not(retracted_at: nil).order(retracted_at: :desc).limit(50)
    end

    def restore_collection
      collection = RecordCollection.retracted.find_by!(name: params[:name])
      Records.restore_collection!(collection)
      redirect_to admin_records_collection_path(collection.name), notice: "Restored #{collection.name}."
    end

    def purge_collection
      collection = RecordCollection.find_by!(name: params[:name])
      return redirect_to admin_records_path, alert: "Type #{collection.name} to purge it." unless params[:confirm_name] == collection.name

      Records.purge_collection!(collection)
      redirect_to admin_records_path, notice: "Purged #{collection.name} and every record in it, for good."
    rescue Records::Error => e
      redirect_to admin_records_path, alert: e.message
    end

    def restore_record
      record = Record.find(params[:id])
      Records.restore!(record, by: Records::Writer.new(principal: current_person, surface: "admin"), reason: params[:reason].presence)
      redirect_to admin_records_collection_path(record.collection.name), notice: "Restored #{record.ref}."
    rescue Records::Error => e
      redirect_to admin_records_path, alert: e.message
    end

    def purge_record
      record = Record.find(params[:id])
      name = record.collection.name
      Records.purge!(record)
      redirect_to admin_records_collection_path(name), notice: "Purged #{record.ref} and its history, for good."
    rescue Records::Error => e
      redirect_to admin_records_path, alert: e.message
    end
  end
end
