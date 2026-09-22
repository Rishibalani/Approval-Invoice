// =========================================================================
//  PN Approval Dispatch Runner
// =========================================================================
//
//  The Job Queue entry point. Drains the outbox one row at a time, committing
//  after each so a single poisonous row cannot roll back a whole batch.
//
//  NEW IN THIS VERSION: THE READINESS GATE
//  ---------------------------------------------------------------------
//
//  The subscriber now captures at insert, before Business Central has opened
//  the approval entry. That is deliberate - see the comment block in
//  PN Approval Event Subscriber for why - but it means a captured row is not
//  automatically ready to send.
//
//  So before each dispatch the runner re-reads the live Approval Entry:
//
//      Created                 -> HOLD. Leave Pending, look again next cycle.
//      Open                    -> SEND.
//      Approved/Rejected/Canc. -> SKIP. Somebody already decided; a card
//                                 would be noise at best and misleading at
//                                 worst.
//      Missing                 -> SKIP. Document posted or request withdrawn.
//
//  This also closes an edge case the subscriber alone could not: an approval
//  cancelled through a path that uses ModifyAll never fires a modify event, so
//  the runner detecting a retired entry on its own is the only thing that
//  stops a stale card going out.
//
//  OTHER DESIGN NOTES
//
//  * Each row is claimed by flipping it to Sending and committing BEFORE the
//    HTTP call. If the session dies mid-call the row is left visibly in
//    Sending and is recoverable with Reset - far better than a row that looks
//    untouched and gets sent twice.
//
//  * The send is wrapped in a TryFunction. An HTTP failure is data, not an
//    exception: it becomes an attempt count and a next-attempt time.
//
//  * Setup.Enabled is honoured here rather than in the subscriber, so pausing
//    the integration buffers events instead of losing them.
//
//  JOB QUEUE ENTRY (created by EnsureJobQueueEntry)
//    Object Type to Run          Codeunit
//    Object ID to Run            50102
//    Recurring                   Yes
//    No. of Minutes between Runs setup: Job Queue Minutes Between Runs
//    Maximum No. of Attempts     setup: Job Queue Max. Attempts
// =========================================================================
// =========================================================================
//  PN Approval Dispatch Runner
// =========================================================================
//
//  The Job Queue entry point. Drains the outbox one row at a time, committing
//  after each so a single poisonous row cannot roll back a whole batch.
//
//  NEW IN THIS VERSION: THE READINESS GATE
//  ---------------------------------------------------------------------
//
//  The subscriber now captures at insert, before Business Central has opened
//  the approval entry. That is deliberate - see the comment block in
//  PN Approval Event Subscriber for why - but it means a captured row is not
//  automatically ready to send.
//
//  So before each dispatch the runner re-reads the live Approval Entry:
//
//      Created                 -> HOLD. Leave Pending, look again next cycle.
//      Open                    -> SEND.
//      Approved/Rejected/Canc. -> SKIP. Somebody already decided; a card
//                                 would be noise at best and misleading at
//                                 worst.
//      Missing                 -> SKIP. Document posted or request withdrawn.
//
//  This also closes an edge case the subscriber alone could not: an approval
//  cancelled through a path that uses ModifyAll never fires a modify event, so
//  the runner detecting a retired entry on its own is the only thing that
//  stops a stale card going out.
//
//  OTHER DESIGN NOTES
//
//  * Each row is claimed by flipping it to Sending and committing BEFORE the
//    HTTP call. If the session dies mid-call the row is left visibly in
//    Sending and is recoverable with Reset - far better than a row that looks
//    untouched and gets sent twice.
//
//  * The send is wrapped in a TryFunction. An HTTP failure is data, not an
//    exception: it becomes an attempt count and a next-attempt time.
//
//  * Setup.Enabled is honoured here rather than in the subscriber, so pausing
//    the integration buffers events instead of losing them.
//
//  JOB QUEUE ENTRY (created by EnsureJobQueueEntry)
//    Object Type to Run          Codeunit
//    Object ID to Run            50102
//    Recurring                   Yes
//    No. of Minutes between Runs setup: Job Queue Minutes Between Runs
//    Maximum No. of Attempts     setup: Job Queue Max. Attempts
// =========================================================================
codeunit 50102 "PN Approval Dispatch Runner"
{
    Access = Public;
    Permissions = tabledata "PN Approval Outbox" = rimd;

    trigger OnRun()
    var
        SweepError: Text;
    begin
        // Dispatch FIRST. Housekeeping second.
        //
        // The order matters more than it looks. The sweep below is upkeep - it
        // notices decisions made elsewhere so stale cards can be retired.
        // Draining the outbox is the job somebody is waiting on.
        //
        // Running the sweep first, and unguarded, meant one bad row anywhere in
        // the table stopped every notification in the queue. The symptom was
        // rows sitting Pending with an attempt count of zero and no error
        // recorded against them, because the failure happened before any row
        // was touched.
        DrainOutbox();

        // Business Central updates approval entries with ModifyAll, which does
        // not raise a modify event per record - so nothing sees an approval
        // happen, whether it came from the web client, a card, or this
        // integration's own callback. Polling is the only reliable answer.
        //
        // Wrapped so a failure here is reported and then ignored. It can cost
        // a stale card; it must never cost a notification.
        if not TrySweepDecidedEntries() then begin
            SweepError := GetLastErrorText();
            ClearLastError();

            Session.LogMessage('PN0010', 'Approval status sweep failed: ' + SweepError,
                Verbosity::Warning, DataClassification::SystemMetadata,
                TelemetryScope::ExtensionPublisher, 'Category', 'PNApprovalDispatch');
        end;
    end;

    var
        AlertSubjectTxt: Label 'Approval dispatch failed - %1 %2', Comment = '%1 = document type, %2 = document no.';
        JobQueueFieldErr: Label '%1 must have a value on the Approval Integration Setup page before the Job Queue Entry can be created.', Comment = '%1 = field caption';

    /// <summary>
    /// Main loop. Safe to call from the Job Queue, a page action, or a test.
    /// </summary>
    procedure DrainOutbox() Succeeded: Integer
    var
        Setup: Record "PN Approval Integration Setup";
        Outbox: Record "PN Approval Outbox";
        Processed: Integer;
    begin
        Setup.GetSetup();
        if not Setup.Enabled then
            exit(0);
        if Setup."Dispatch Endpoint URL" = '' then
            exit(0);

        // Fail the run, loudly and by field name, before any row is claimed.
        // The values checked here have no defaults in code any more.
        Setup.TestTimingAndPolicySetup();

        Outbox.SetCurrentKey(Status, "Next Attempt At");
        Outbox.SetFilter(Status, '%1|%2',
            "PN Approval Outbox Status"::Pending,
            "PN Approval Outbox Status"::Retrying);
        Outbox.SetFilter("Next Attempt At", '<=%1', CurrentDateTime());

        if Outbox.FindSet() then
            repeat
                Processed += 1;
                if DispatchOne(Outbox, Setup) then
                    Succeeded += 1;
            until (Outbox.Next() = 0) or (Processed >= Setup."Batch Size");

        if Succeeded > 0 then begin
            Setup.GetSetup();
            Setup."Last Dispatch At" := CurrentDateTime();
            Setup.Modify(true);
            Commit();
        end;

        PurgeOldRows(Setup);
        exit(Succeeded);
    end;

    local procedure DispatchOne(var Outbox: Record "PN Approval Outbox"; var Setup: Record "PN Approval Integration Setup") Ok: Boolean
    var
        HttpClientCU: Codeunit "PN Approval Http Client";
        Payload: Text;
        ErrorText: Text;
        HoldReason: Text;
        // Inline Option rather than a separate enum object: the readiness
        // verdict never leaves this codeunit, so it does not need an object ID.
        Readiness: Option Send,Hold,Skip;
    begin
        // ---- Readiness gate --------------------------------------------
        Readiness := EvaluateReadiness(Outbox, HoldReason);

        if Readiness = Readiness::Skip then begin
            Outbox.Status := Outbox.Status::Skipped;
            Outbox."Last Error" := CopyStr(HoldReason, 1, MaxStrLen(Outbox."Last Error"));
            Outbox.Modify(true);
            Commit();
            exit(false);
        end;

        if Readiness = Readiness::Hold then begin
            // Stay Pending and look again shortly. Attempt Count is NOT
            // incremented - waiting for Business Central to open the entry is
            // not a failed delivery attempt, and counting it as one would burn
            // through Max Attempts before the row was ever eligible to send.
            // The wait is Created Hold Delay on setup; * 1000 is seconds to ms.
            Outbox."Next Attempt At" := CurrentDateTime() + (Setup.GetCreatedHoldDelaySec() * 1000);
            Outbox."Last Error" := CopyStr(HoldReason, 1, MaxStrLen(Outbox."Last Error"));
            Outbox.Modify(true);
            Commit();
            exit(false);
        end;

        // ---- Claim -----------------------------------------------------
        // Committed before the HTTP call so a crash leaves visible evidence.
        Outbox.Status := Outbox.Status::Sending;
        Outbox."Last Error" := '';
        Outbox.Modify(true);

        // ---- Risk flags, re-checked against current policy --------------
        //
        // Before anything is sent, and before the payload is built, so both
        // the email and the card agree. See the procedure for why this happens
        // a second time.
        RefreshRiskFlags(Outbox, Setup);

        // ---- Outlook, sent from here -----------------------------------
        //
        // Business Central composes and sends the approval email itself, so it
        // happens alongside the Azure dispatch rather than as part of it.
        // Azure still owns the buttons: every link carries a signed token that
        // only the action endpoint can act on.
        //
        // AFTER the Last Error clear, not before. Placing it earlier meant any
        // failure reason it recorded was wiped by that clear one line later,
        // which produced a silent failure with a blank diagnostic.
        //
        // Deliberately not allowed to fail the row. If the email bounces but
        // Teams succeeds, the approver has still been reached, and the outbox
        // status tracks the dispatch to Azure rather than the email.
        SendOutlookEmail(Outbox, Setup);
        Outbox.Modify(true);
        Commit();

        if not TryBuildPayload(Outbox, Payload) then begin
            ErrorText := GetLastErrorText();
            ClearLastError();
            Outbox.Get(Outbox."Entry No.");
            Outbox.RegisterFailure('Payload build failed: ' + ErrorText, 0);
            Commit();
            exit(false);
        end;

        if Setup."Verbose Logging" then begin
            Outbox.Get(Outbox."Entry No.");
            Outbox.SetRequestBody(Payload);
            Outbox.Modify(true);
        end;

        Ok := HttpClientCU.TryPost(Outbox, Payload);

        Outbox.Get(Outbox."Entry No.");

        if Setup."Verbose Logging" then
            Outbox.SetResponseBody(HttpClientCU.GetLastResponseBody());

        if Ok then
            Outbox.RegisterSuccess(HttpClientCU.GetLastHttpStatus(), HttpClientCU.GetLastDurationMs())
        else begin
            ErrorText := GetLastErrorText();
            ClearLastError();
            Outbox.RegisterFailure(ErrorText, HttpClientCU.GetLastHttpStatus());

            // Only alert once we have given up. Alerting on every transient
            // failure trains people to ignore the alerts.
            if Outbox.Status = Outbox.Status::Failed then
                SendFailureAlert(Outbox, Setup, ErrorText);
        end;

        Commit();
        exit(Ok);
    end;

    // ------------------------------------------------------------------
    //  Is this row ready to send?
    //
    //  Returns an Integer because that is what an Option is backed by; the
    //  caller assigns it straight into its own Option variable.
    // ------------------------------------------------------------------
    local procedure EvaluateReadiness(var Outbox: Record "PN Approval Outbox"; var Reason: Text): Integer
    var
        ApprovalEntry: Record "Approval Entry";
        Readiness: Option Send,Hold,Skip;
    begin
        Reason := '';

        // Status-change events describe something that already happened, so
        // there is nothing to wait for.
        if Outbox."Event Type" <> Outbox."Event Type"::Requested then
            exit(Readiness::Send);

        if not ApprovalEntry.Get(Outbox."Approval Entry No.") then begin
            Reason := 'Approval entry no longer exists - document posted or request withdrawn.';
            exit(Readiness::Skip);
        end;

        case ApprovalEntry.Status of
            ApprovalEntry.Status::Created:
                begin
                    // Business Central has not opened it yet. Normal for a few
                    // seconds; persistent means the workflow never assigned an
                    // approver, which is a configuration problem upstream.
                    Reason := 'Waiting for Business Central to open the approval entry.';
                    exit(Readiness::Hold);
                end;
            ApprovalEntry.Status::Open:
                exit(Readiness::Send);
            else begin
                Reason := StrSubstNo(
                    'Already %1 before dispatch - no notification needed.',
                    Format(ApprovalEntry.Status));
                exit(Readiness::Skip);
            end;
        end;
    end;

    /// <summary>
    /// Finds approvals that were decided without an outbox row being written,
    /// and writes one.
    ///
    /// Looks only at requests this integration actually sent - if no card or
    /// email went out, there is nothing to retire. Each decided entry gets one
    /// status row, and the check for an existing row means running every
    /// minute costs nothing after the first time.
    /// </summary>
    [TryFunction]
    local procedure TrySweepDecidedEntries()
    begin
        SweepDecidedEntries();
    end;

    local procedure SweepDecidedEntries()
    var
        Outbox: Record "PN Approval Outbox";
        ApprovalEntry: Record "Approval Entry";
        Subscriber: Codeunit "PN Approval Event Subscriber";
        EventType: Enum "PN Approval Event Type";
    begin
        Outbox.SetRange("Event Type", Outbox."Event Type"::Requested);
        Outbox.SetRange(Status, Outbox.Status::Sent);

        if not Outbox.FindSet() then
            exit;

        repeat
            // Skipped when the entry is gone. Business Central removes
            // approval entries in some configurations once a document is
            // released, and capturing from a record that was never read would
            // write a row of blanks - which is worse than no row, because it
            // looks like data.
            //
            // A card for a deleted entry keeps its buttons, and they fail
            // safely: Business Central reports the request no longer exists.
            if ApprovalEntry.Get(Outbox."Approval Entry No.") then begin
                case ApprovalEntry.Status of
                    ApprovalEntry.Status::Approved:
                        EventType := EventType::Approved;
                    ApprovalEntry.Status::Rejected:
                        EventType := EventType::Rejected;
                    ApprovalEntry.Status::Canceled:
                        EventType := EventType::Cancelled;
                    else
                        EventType := EventType::Requested;
                end;

                if EventType <> EventType::Requested then
                    if not StatusRowExists(Outbox."Approval Entry No.", EventType) then
                        Subscriber.CaptureApprovalEntry(ApprovalEntry, EventType);
            end;
        until Outbox.Next() = 0;
    end;

    local procedure StatusRowExists(ApprovalEntryNo: Integer; EventType: Enum "PN Approval Event Type"): Boolean
    var
        Existing: Record "PN Approval Outbox";
    begin
        Existing.SetRange("Approval Entry No.", ApprovalEntryNo);
        Existing.SetRange("Event Type", EventType);
        exit(not Existing.IsEmpty());
    end;

    /// <summary>
    /// Re-evaluates the high-value and bank-change flags at dispatch time.
    ///
    /// WHY THIS HAPPENS TWICE
    ///
    /// The subscriber already set these at capture. That is deliberate and
    /// stays - it records what was true when the request was raised, and it is
    /// the only evaluation that happens if the row is dispatched immediately.
    ///
    /// But Business Central creates the WHOLE approval chain at submission,
    /// all entries at once. A three-level chain produces three outbox rows in
    /// the same second, and the third may not be sent for half an hour. Every
    /// flag on it was stamped against settings as they stood before anybody
    /// had approved anything.
    ///
    /// So an administrator who tightens a threshold mid-chain, or a vendor
    /// whose bank details change between approvals, has no effect on anyone
    /// already queued. That is the wrong way round: a threshold is a POLICY,
    /// and policy should be whatever it says when the notification actually
    /// goes out.
    ///
    /// FLAGS ONLY EVER TIGHTEN
    ///
    /// Set to true here, never back to false. Once something has been marked
    /// as needing a signed-in review, a later loosening of the setting must
    /// not quietly un-mark it - the reason it was flagged may no longer be
    /// visible, and silently downgrading a control is not a thing to do by
    /// accident.
    ///
    /// The AMOUNT stays frozen. That is a fact about the document, and the
    /// approver is judged against what the request said. Only the policy
    /// applied to it is re-read.
    /// </summary>
    local procedure RefreshRiskFlags(var Outbox: Record "PN Approval Outbox"; var Setup: Record "PN Approval Integration Setup")
    var
        ApprovalEntry: Record "Approval Entry";
        UserSetup: Record "User Setup";
        Subscriber: Codeunit "PN Approval Event Subscriber";
        Threshold: Decimal;
        Changed: Boolean;
    begin
        // Only a live request carries buttons, so only a live request needs
        // its risk flags kept current.
        if Outbox."Event Type" <> Outbox."Event Type"::Requested then
            exit;

        if not ApprovalEntry.Get(Outbox."Approval Entry No.") then
            exit;

        // ---- High value, against the threshold as it stands NOW ----
        if not Outbox."High Value" then begin
            Threshold := Setup."High Value Threshold (LCY)";

            if UserSetup.Get(Outbox."Approver User ID") then
                Threshold := UserSetup.PNEffectiveHighValueThreshold(Threshold);

            if (Threshold > 0) and (Abs(Outbox."Amount (LCY)") >= Threshold) then begin
                Outbox."High Value" := true;
                Changed := true;
            end;
        end;

        // ---- Bank details, against changes made since capture ----
        if Setup."Block On Vendor Bank Change" then
            if not Outbox."Bank Details Changed" then
                if Subscriber.VendorBankDetailsChanged(ApprovalEntry) then begin
                    Outbox."Bank Details Changed" := true;
                    Changed := true;
                end;

        if Changed then
            Outbox.Modify(true);
    end;

    /// <summary>
    /// Sends the Outlook approval email, if that channel is switched on.
    ///
    /// Failures are logged on the row's Last Error and otherwise swallowed.
    /// An email that could not be sent is worth knowing about; it is not worth
    /// holding up the Teams card that went out fine, and a retry would
    /// re-send the successful one.
    /// </summary>
    local procedure SendOutlookEmail(var Outbox: Record "PN Approval Outbox"; var Setup: Record "PN Approval Integration Setup")
    var
        FailureReason: Text;
    begin
        // Every exit path records WHY. A channel that silently declines to
        // send is indistinguishable from one that is broken, and "no error
        // anywhere" is the hardest state to diagnose.
        if not Setup."Outlook Channel Enabled" then begin
            NoteEmailOutcome(Outbox, 'skipped - Outlook is switched off on Approval Channel Setup');
            exit;
        end;

        // Only a live request produces an email. Status changes are recorded
        // in Business Central and do not need a second announcement.
        if Outbox."Event Type" <> Outbox."Event Type"::Requested then begin
            NoteEmailOutcome(Outbox, 'skipped - not an approval request');
            exit;
        end;

        if TrySendOutlookEmail(Outbox, FailureReason) then begin
            NoteEmailOutcome(Outbox, 'sent');
            exit;
        end;

        if FailureReason = '' then
            FailureReason := GetLastErrorText();

        ClearLastError();

        if FailureReason = '' then
            FailureReason := 'failed, no reason reported';

        NoteEmailOutcome(Outbox, FailureReason);
    end;

    /// <summary>
    /// Records what happened to the email on the outbox row.
    ///
    /// Appended rather than assigned, because the row's Last Error also
    /// carries the HTTP dispatch result. Overwriting would mean whichever
    /// finished last won, and the other outcome would vanish.
    /// </summary>
    local procedure NoteEmailOutcome(var Outbox: Record "PN Approval Outbox"; Outcome: Text)
    var
        Combined: Text;
    begin
        Combined := 'Email: ' + Outcome;

        if Outbox."Last Error" <> '' then
            Combined := Outbox."Last Error" + ' | ' + Combined;

        Outbox."Last Error" := CopyStr(Combined, 1, MaxStrLen(Outbox."Last Error"));
        Outbox.Modify(true);
    end;

    [TryFunction]
    local procedure TrySendOutlookEmail(var Outbox: Record "PN Approval Outbox"; var FailureReason: Text)
    var
        EmailSender: Codeunit "PN Approval Email Sender";
    begin
        if not EmailSender.TrySendApprovalEmail(Outbox, FailureReason) then
            Error(FailureReason);
    end;

    [TryFunction]
    local procedure TryBuildPayload(var Outbox: Record "PN Approval Outbox"; var Payload: Text)
    var
        PayloadBuilder: Codeunit "PN Approval Payload Builder";
    begin
        Payload := PayloadBuilder.Build(Outbox);
    end;

    // ------------------------------------------------------------------
    //  Housekeeping. Delivered rows are an operational convenience, not the
    //  permanent record - that is the Approval Entry and its comment lines.
    // ------------------------------------------------------------------
    local procedure PurgeOldRows(var Setup: Record "PN Approval Integration Setup")
    var
        Outbox: Record "PN Approval Outbox";
        CutOff: DateTime;
    begin
        if Setup."Log Retention (Days)" <= 0 then
            exit;

        CutOff := CreateDateTime(Today() - Setup."Log Retention (Days)", 0T);

        Outbox.SetFilter(Status, '%1|%2',
            "PN Approval Outbox Status"::Sent,
            "PN Approval Outbox Status"::Skipped);
        Outbox.SetFilter("Created At", '<%1', CutOff);
        if not Outbox.IsEmpty() then begin
            Outbox.DeleteAll(false);
            Commit();
        end;
    end;

    local procedure SendFailureAlert(var Outbox: Record "PN Approval Outbox"; var Setup: Record "PN Approval Integration Setup"; ErrorText: Text)
    var
        EmailMessage: Codeunit "Email Message";
        Email: Codeunit Email;
        Recipients: List of [Text];
        Body: Text;
    begin
        if Setup."Alert Email Recipients".Trim() = '' then
            exit;

        Recipients := Setup."Alert Email Recipients".Split(',');

        Body :=
            'An approval notification could not be delivered after ' + Format(Outbox."Attempt Count") + ' attempts.<br/><br/>' +
            '<b>Document:</b> ' + Format(Outbox."Document Type") + ' ' + Outbox."Document No." + '<br/>' +
            '<b>Approver:</b> ' + Outbox."Approver User ID" + '<br/>' +
            '<b>Amount (LCY):</b> ' + Format(Outbox."Amount (LCY)") + '<br/>' +
            '<b>Approval Entry No.:</b> ' + Format(Outbox."Approval Entry No.") + '<br/>' +
            '<b>Outbox Entry No.:</b> ' + Format(Outbox."Entry No.") + '<br/>' +
            '<b>Last HTTP status:</b> ' + Format(Outbox."Last HTTP Status") + '<br/><br/>' +
            '<b>Error:</b><br/>' + ErrorText + '<br/><br/>' +
            'The approval itself is unaffected and can still be actioned in Business Central.<br/><br/>' +
            'Regards,<br/>PulseNet365 Approval Bridge';

        EmailMessage.Create(
            Recipients,
            StrSubstNo(AlertSubjectTxt, Format(Outbox."Document Type"), Outbox."Document No."),
            Body,
            true);

        Email.Send(EmailMessage, Enum::"Email Scenario"::Notification);
    end;

    // ------------------------------------------------------------------
    //  Job Queue provisioning, driven from the setup page.
    // ------------------------------------------------------------------
    procedure EnsureJobQueueEntry()
    var
        Setup: Record "PN Approval Integration Setup";
        JobQueueEntry: Record "Job Queue Entry";
    begin
        // Recurrence and attempts come from setup. An entry that already
        // exists is left alone, so changing these later needs the Job Queue
        // Entry edited (or deleted and recreated from the setup page).
        Setup.GetSetup();
        if Setup."Job Queue Minutes Between Runs" <= 0 then
            Error(JobQueueFieldErr, Setup.FieldCaption("Job Queue Minutes Between Runs"));
        if Setup."Job Queue Max Attempts" <= 0 then
            Error(JobQueueFieldErr, Setup.FieldCaption("Job Queue Max Attempts"));

        JobQueueEntry.SetRange("Object Type to Run", JobQueueEntry."Object Type to Run"::Codeunit);
        JobQueueEntry.SetRange("Object ID to Run", Codeunit::"PN Approval Dispatch Runner");
        if not JobQueueEntry.IsEmpty() then
            exit;

        JobQueueEntry.Init();
        JobQueueEntry.ID := CreateGuid();
        JobQueueEntry."Object Type to Run" := JobQueueEntry."Object Type to Run"::Codeunit;
        JobQueueEntry."Object ID to Run" := Codeunit::"PN Approval Dispatch Runner";
        JobQueueEntry.Description := CopyStr('Dispatch approval notifications to Azure', 1, MaxStrLen(JobQueueEntry.Description));
        JobQueueEntry."Run in User Session" := false;
        JobQueueEntry."Recurring Job" := true;
        JobQueueEntry."No. of Minutes between Runs" := Setup."Job Queue Minutes Between Runs";
        JobQueueEntry."Run on Mondays" := true;
        JobQueueEntry."Run on Tuesdays" := true;
        JobQueueEntry."Run on Wednesdays" := true;
        JobQueueEntry."Run on Thursdays" := true;
        JobQueueEntry."Run on Fridays" := true;
        JobQueueEntry."Run on Saturdays" := true;
        JobQueueEntry."Run on Sundays" := true;
        JobQueueEntry."Maximum No. of Attempts to Run" := Setup."Job Queue Max Attempts";
        JobQueueEntry.Insert(true);

        JobQueueEntry.SetStatus(JobQueueEntry.Status::Ready);
    end;
}
