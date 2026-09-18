// =========================================================================
//  PN Approval Event Subscriber
// =========================================================================
//
//  WHY TABLE 454 AND NOT THE WORKFLOW EVENTS
//
//  The obvious extension points are the workflow event codes in codeunit 1520
//  or the integration events in codeunit 1535 ("Approvals Mgmt."). Both fire at
//  document-submission time, before the per-approver Approval Entry records
//  exist. In a two-level chain that gives you one trigger for the whole
//  document and no clean way to know which approver to notify next.
//
//  Subscribing to the Approval Entry table gives exactly one trigger per
//  approver, in the right order, and it makes chain progression free: Business
//  Central creates approver two's entry only after approver one approves, and
//  that fires this subscriber again.
//
//  ---------------------------------------------------------------------
//  THE STATUS LIFECYCLE - READ THIS BEFORE CHANGING ANYTHING BELOW
//  ---------------------------------------------------------------------
//
//  Business Central does NOT insert an Approval Entry as Open. It inserts it
//  as Created, then updates it to Open in a second step once the workflow has
//  worked out who the request goes to.
//
//      INSERT   Status = Created     <- nobody is being asked anything yet
//      MODIFY   Status = Open        <- THIS is the moment the approver is asked
//      MODIFY   Status = Approved / Rejected / Canceled
//
//  So the notification trigger is the MODIFY to Open, not the insert.
//
//  An earlier version of this file checked for Open inside the insert
//  subscriber and exited when it was Created - which is always, so nothing
//  was ever written to the outbox. The approval itself worked fine, which is
//  what made it confusing: the document reached Pending Approval, the entries
//  existed, and the outbox stayed empty.
//
//  Both subscribers are kept because some code paths do insert directly as
//  Open. The duplicate guard in EnqueueEvent makes handling both safe.
//
//  THE OTHER RULE IN THIS FILE: no HTTP, no long-running work, no Commit.
//  This code runs inside the user's transaction. It inserts a row and gets out.
// =========================================================================
// =========================================================================
//  PN Approval Event Subscriber
// =========================================================================
//
//  WHY TABLE 454 AND NOT THE WORKFLOW EVENTS
//
//  The obvious extension points are the workflow event codes in codeunit 1520
//  or the integration events in codeunit 1535 ("Approvals Mgmt."). Both fire at
//  document-submission time, before the per-approver Approval Entry records
//  exist. In a two-level chain that gives you one trigger for the whole
//  document and no clean way to know which approver to notify next.
//
//  Subscribing to the Approval Entry table gives exactly one trigger per
//  approver, in the right order, and it makes chain progression free: Business
//  Central creates approver two's entry only after approver one approves, and
//  that fires this subscriber again.
//
//  ---------------------------------------------------------------------
//  THE STATUS LIFECYCLE - READ THIS BEFORE CHANGING ANYTHING BELOW
//  ---------------------------------------------------------------------
//
//  Business Central does NOT insert an Approval Entry as Open. It inserts it
//  as Created, then updates it to Open in a second step once the workflow has
//  worked out who the request goes to.
//
//      INSERT   Status = Created     <- nobody is being asked anything yet
//      MODIFY   Status = Open        <- THIS is the moment the approver is asked
//      MODIFY   Status = Approved / Rejected / Canceled
//
//  So the notification trigger is the MODIFY to Open, not the insert.
//
//  An earlier version of this file checked for Open inside the insert
//  subscriber and exited when it was Created - which is always, so nothing
//  was ever written to the outbox. The approval itself worked fine, which is
//  what made it confusing: the document reached Pending Approval, the entries
//  existed, and the outbox stayed empty.
//
//  Both subscribers are kept because some code paths do insert directly as
//  Open. The duplicate guard in EnqueueEvent makes handling both safe.
//
//  THE OTHER RULE IN THIS FILE: no HTTP, no long-running work, no Commit.
//  This code runs inside the user's transaction. It inserts a row and gets out.
// =========================================================================
// =========================================================================
//  PN Approval Event Subscriber
// =========================================================================
//
//  WHY THIS CAPTURES AT INSERT WITH NO STATUS CHECK
//  ---------------------------------------------------------------------
//
//  Business Central moves an Approval Entry through this lifecycle:
//
//      INSERT   Status = Created     <- Approver ID is already set here
//      bulk     Status = Open        <- ApprovalsMgmt uses ModifyAll
//      MODIFY   Status = Approved / Rejected / Canceled
//
//  The middle step is the problem. ModifyAll performs a bulk SQL update and
//  does NOT raise OnAfterModifyEvent per record. So a subscriber waiting for
//  the modify to Open waits forever.
//
//  Two earlier attempts both failed on this:
//    1. Insert subscriber that required Status = Open  -> always exited,
//       because at insert the status is Created.
//    2. Modify subscriber watching for Created -> Open -> never fired,
//       because that transition is a ModifyAll.
//
//  Symptom in both cases: the document reaches Pending Approval, the approval
//  entries exist and look correct, and the outbox stays completely empty.
//
//  SO: capture every insert, whatever the status, and let the dispatch runner
//  decide when the row is ready to send. The runner re-reads the live approval
//  entry and holds the row as Pending while the status is still Created.
//
//  This is more robust than hooking a specific transition, because it depends
//  only on Insert() being called - which it always is, and which has no bulk
//  alternative in the approval framework. It also survives Microsoft changing
//  ApprovalsMgmt internals between releases.
//
//  Cost: up to one Job Queue cycle of latency. With a one-minute recurrence
//  that is not worth optimising away.
//
//  THE RULE IN THIS FILE: no HTTP, no long-running work, no Commit. This code
//  runs inside the user's transaction. It inserts a row and gets out.
// =========================================================================
codeunit 50101 "PN Approval Event Subscriber"
{
    Access = Internal;

    // ------------------------------------------------------------------
    //  Insert - the reliable hook.
    //
    //  No status filter. Whatever state the entry arrives in, capture it.
    //  Readiness is the runner's problem.
    // ------------------------------------------------------------------
    [EventSubscriber(ObjectType::Table, Database::"Approval Entry", 'OnAfterInsertEvent', '', false, false)]
    local procedure OnAfterInsertApprovalEntry(var Rec: Record "Approval Entry"; RunTrigger: Boolean)
    begin
        if Rec.IsTemporary() then
            exit;

        // Already-decided entries are history, not requests. Nothing to notify.
        if Rec.Status in [Rec.Status::Approved, Rec.Status::Rejected, Rec.Status::Canceled] then
            exit;

        if not IsInScope(Rec) then
            exit;

        CaptureApprovalEntry(Rec, "PN Approval Event Type"::Requested);
    end;

    // ------------------------------------------------------------------
    //  Modify - a secondary path, kept for status changes.
    //
    //  Approve and Reject go through Modify() rather than ModifyAll, so these
    //  DO fire. Cancel may go either way depending on the code path, which is
    //  why the runner also detects retired entries on its own rather than
    //  relying on this alone.
    // ------------------------------------------------------------------
    [EventSubscriber(ObjectType::Table, Database::"Approval Entry", 'OnAfterModifyEvent', '', false, false)]
    local procedure OnAfterModifyApprovalEntry(var Rec: Record "Approval Entry"; var xRec: Record "Approval Entry"; RunTrigger: Boolean)
    begin
        if Rec.IsTemporary() then
            exit;

        // Only status transitions matter. Approval entries get modified for
        // other reasons - due dates, comment counts - and none of those should
        // raise a notification.
        if Rec.Status = xRec.Status then
            exit;

        if not IsInScope(Rec) then
            exit;

        case Rec.Status of
            Rec.Status::Open:
                // Belt and braces. If a future release switches ModifyAll for
                // Modify, this starts firing - and the duplicate guard in
                // CaptureApprovalEntry makes that harmless rather than a bug.
                CaptureApprovalEntry(Rec, "PN Approval Event Type"::Requested);
            Rec.Status::Approved:
                CaptureApprovalEntry(Rec, "PN Approval Event Type"::Approved);
            Rec.Status::Rejected:
                CaptureApprovalEntry(Rec, "PN Approval Event Type"::Rejected);
            Rec.Status::Canceled:
                CaptureApprovalEntry(Rec, "PN Approval Event Type"::Cancelled);
        end;
    end;

    // ------------------------------------------------------------------
    //  Scope filter
    // ------------------------------------------------------------------
    local procedure IsInScope(var ApprovalEntry: Record "Approval Entry"): Boolean
    var
        Setup: Record "PN Approval Integration Setup";
    begin
        // Deliberately NOT gated on Setup.Enabled. When the integration is
        // paused we still want the rows, so nothing is lost - the runner is
        // what respects that switch.
        //
        // Setup is per-company. If the record does not exist in this company,
        // nothing is configured and there is nothing sensible to capture.
        if not Setup.Get() then
            exit(false);

        case ApprovalEntry."Table ID" of
            Database::"Purchase Header":
                if not Setup."Include Purchase Documents" then
                    exit(false);
            Database::"Sales Header":
                if not Setup."Include Sales Documents" then
                    exit(false);
            else
                exit(false);
        end;

        // Invoices and credit memos only. Orders and quotes use the same
        // approval framework but sit outside this solution's scope.
        if not (ApprovalEntry."Document Type" in [
            ApprovalEntry."Document Type"::Invoice,
            ApprovalEntry."Document Type"::"Credit Memo"])
        then
            exit(false);

        // Below the floor the approver simply works in Business Central.
        // Uses Amount (LCY) so a threshold means the same across currencies.
        if Setup."Min. Amount (LCY)" > 0 then
            if Abs(ApprovalEntry."Amount (LCY)") < Setup."Min. Amount (LCY)" then
                exit(false);

        exit(true);
    end;

    // ------------------------------------------------------------------
    //  Write the outbox row. Same transaction as the Approval Entry.
    //
    //  Internal rather than local so the diagnostics page can backfill rows
    //  for approvals that were raised before this extension was published.
    // ------------------------------------------------------------------
    // Plain procedure, not internal. The codeunit is Access = Internal, which
    // already confines this to the extension; marking the procedure internal
    // as well makes it unreachable from the dispatch runner, which is
    // Access = Public. See VendorBankDetailsChanged for the same note.
    procedure CaptureApprovalEntry(var ApprovalEntry: Record "Approval Entry"; EventType: Enum "PN Approval Event Type")
    var
        Outbox: Record "PN Approval Outbox";
        Setup: Record "PN Approval Integration Setup";
        UserSetup: Record "User Setup";
        User: Record User;
        Threshold: Decimal;
    begin
        Setup.GetSetup();

        // Duplicate guard. This is what makes it safe to hook both the insert
        // and the modify, and safe to run a backfill over rows that may
        // already be captured. Whichever writes first wins; the rest are
        // no-ops. Failed rows are excluded so a manual retry can re-raise one.
        Outbox.SetRange("Approval Entry No.", ApprovalEntry."Entry No.");
        Outbox.SetRange("Event Type", EventType);
        Outbox.SetFilter(Status, '<>%1', "PN Approval Outbox Status"::Failed);
        if not Outbox.IsEmpty() then
            exit;

        Outbox.Init();
        Outbox."Event Type" := EventType;
        Outbox."Approval Entry No." := ApprovalEntry."Entry No.";
        Outbox."Record ID to Approve" := ApprovalEntry."Record ID to Approve";
        Outbox."Table ID" := ApprovalEntry."Table ID";
        Outbox."Document Type" := ApprovalEntry."Document Type";
        Outbox."Document No." := ApprovalEntry."Document No.";
        Outbox."Sequence No." := ApprovalEntry."Sequence No.";
        Outbox."Approver User ID" := ApprovalEntry."Approver ID";
        Outbox."Sender User ID" := ApprovalEntry."Sender ID";
        Outbox.Amount := ApprovalEntry.Amount;
        Outbox."Amount (LCY)" := ApprovalEntry."Amount (LCY)";
        Outbox."Currency Code" := ApprovalEntry."Currency Code";

        // Approver ID is a User Name. Resolve it to the stable security ID now,
        // while the User table is cheap to reach.
        User.SetRange("User Name", ApprovalEntry."Approver ID");
        if User.FindFirst() then
            Outbox."Approver User Security ID" := User."User Security ID";

        // Financial gates are frozen at capture time, so the decision is made
        // against the amount as submitted rather than whatever the document
        // says by the time the queue drains.
        // The stricter of the global ceiling and any personal override. A
        // personal value can only tighten the control, never loosen it.
        Threshold := Setup."High Value Threshold (LCY)";
        if UserSetup.Get(ApprovalEntry."Approver ID") then
            Threshold := UserSetup.PNEffectiveHighValueThreshold(Threshold);

        if (Threshold > 0) and (Abs(ApprovalEntry."Amount (LCY)") >= Threshold) then
            Outbox."High Value" := true;

        if Setup."Block On Vendor Bank Change" then
            Outbox."Bank Details Changed" := VendorBankDetailsChanged(ApprovalEntry);

        Outbox.Status := Outbox.Status::Pending;
        Outbox.Insert(true);
    end;

    /// <summary>
    /// Entry point for the diagnostics page backfill. Applies the same scope
    /// filter and duplicate guard as the live path, so it can never create a
    /// row the subscriber itself would have rejected, and running it twice
    /// changes nothing.
    /// </summary>
    procedure BackfillApprovalEntry(var ApprovalEntry: Record "Approval Entry")
    begin
        if ApprovalEntry.Status <> ApprovalEntry.Status::Open then
            exit;
        if not IsInScope(ApprovalEntry) then
            exit;

        CaptureApprovalEntry(ApprovalEntry, "PN Approval Event Type"::Requested);
    end;

    // ------------------------------------------------------------------
    //  Vendor bank-change gate
    //
    //  PREREQUISITE: Change Log must be active for table 23 (Vendor) with the
    //  bank fields selected. Without it this always returns false and the
    //  control silently does nothing.
    //
    //  VERIFY THE FIELD NUMBERS. 288/289/290 are placeholders and differ by
    //  localisation. Wrong numbers mean the fraud gate never fires.
    // ------------------------------------------------------------------
    /// <summary>
    /// Callable from the dispatch runner so the bank check can be re-run at
    /// send time without duplicating the Change Log query. One implementation,
    /// two callers - a second copy would drift the moment a field number
    /// changed.
    ///
    /// Declared plainly rather than as internal. The codeunit itself is
    /// Access = Internal, which already keeps this inside the extension, and
    /// marking the procedure internal as well made it unreachable from the
    /// runner - which is Access = Public - with "inaccessible due to its
    /// protection level". One restriction is enough.
    /// </summary>
    procedure VendorBankDetailsChanged(var ApprovalEntry: Record "Approval Entry"): Boolean
    var
        PurchaseHeader: Record "Purchase Header";
        ChangeLogEntry: Record "Change Log Entry";
        RecRef: RecordRef;
    begin
        if ApprovalEntry."Table ID" <> Database::"Purchase Header" then
            exit(false);

        if not RecRef.Get(ApprovalEntry."Record ID to Approve") then
            exit(false);
        RecRef.SetTable(PurchaseHeader);

        if PurchaseHeader."Buy-from Vendor No." = '' then
            exit(false);

        ChangeLogEntry.SetRange("Table No.", Database::Vendor);
        ChangeLogEntry.SetRange("Primary Key Field 1 Value", PurchaseHeader."Buy-from Vendor No.");
        ChangeLogEntry.SetFilter("Date and Time", '>%1', CreateDateTime(PurchaseHeader."Document Date", 0T));
        ChangeLogEntry.SetFilter("Field No.", '%1|%2|%3',
            288,   // Bank Account No.
            289,   // Bank Branch No.
            290);  // IBAN - confirm against your localisation
        exit(not ChangeLogEntry.IsEmpty());
    end;
}
