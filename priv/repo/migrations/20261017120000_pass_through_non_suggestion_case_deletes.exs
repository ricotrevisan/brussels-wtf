defmodule BrusselsWtf.Repo.Migrations.PassThroughNonSuggestionCaseDeletes do
  use Ecto.Migration

  # A BEFORE row trigger that returns NULL silently cancels the row operation.
  # The previous version returned NEW for non-suggestion cases, which is NULL on
  # DELETE. Only that branch changes; suggestion rules are unchanged.
  def up do
    execute function_sql("COALESCE(NEW, OLD)")
  end

  def down do
    execute function_sql("NEW")
  end

  defp function_sql(non_suggestion_result) do
    """
    CREATE OR REPLACE FUNCTION enforce_suggestion_review_case_lifecycle()
    RETURNS trigger AS $$
    DECLARE
      decision_action text;
    BEGIN
      IF OLD.kind <> 'suggestion' THEN
        RETURN #{non_suggestion_result};
      END IF;
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'suggestion review cases cannot be deleted';
      END IF;
      SELECT action INTO decision_action FROM review_suggestion_decisions WHERE review_case_id = OLD.id;
      IF OLD.status = 'open' AND NEW.status = 'resolved' AND
         ((NEW.disposition = 'suggestion_rejected' AND decision_action = 'reject') OR
          (NEW.disposition = 'suggestion_approved' AND decision_action = 'approve') OR
          (NEW.disposition = 'suggestion_addressed' AND decision_action = 'address')) AND
         (to_jsonb(NEW) - ARRAY['status', 'disposition', 'updated_at']) =
         (to_jsonb(OLD) - ARRAY['status', 'disposition', 'updated_at']) THEN
        RETURN NEW;
      END IF;
      RAISE EXCEPTION 'suggestion review cases require the dedicated moderation lifecycle';
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
