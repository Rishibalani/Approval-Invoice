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
//  RECOMMENDED JOB QUEUE ENTRY
//    Object Type to Run          Codeunit
//    Object ID to Run            50922
//    Recurring                   Yes
//    No. of Minutes between Runs 1
//    Maximum No. of Attempts     3
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
//  RECOMMENDED JOB QUEUE ENTRY
//    Object Type to Run          Codeunit
//    Object ID to Run            50102
//    Recurring                   Yes
//    No. of Minutes between Runs 1
//    Maximum No. of Attempts     3
// =========================================================================
codeunit 50102 "PN Approval Dispatch Runner"
{
    Access = Public;
    Permissions = tabledata "PN Approval Outbox" = rimd;

    trigger OnRun()
    begin
        DrainOutbox();
    end;

    var
        AlertSubjectTxt: Label 'Approval dispatch failed - %1 %2', Comment = '%1 = document type, %2 = document no.';

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
            Outbox."Next Attempt At" := CurrentDateTime() + 30000;
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

        // ---- Outlook, sent from here -----------------------------------
        //
        // Business Central composes and sends the approval email itself, so it
        // happens alongside the Azure dispatch rather than as part of it.
        // Azure still owns the buttons: every link carries a signed token that
        // only the action endpoint can act on.
        //
        // AFTER the Last Error clear, not before. Placing it earlier meant any
        // failure reason it recorded was wiped by that clear one line later,
        // which produced a silent failure with a blank diagnostic - the worst
        // combination, because it looks like nothing was attempted.
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
        JobQueueEntry: Record "Job Queue Entry";
    begin
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
        JobQueueEntry."No. of Minutes between Runs" := 1;
        JobQueueEntry."Run on Mondays" := true;
        JobQueueEntry."Run on Tuesdays" := true;
        JobQueueEntry."Run on Wednesdays" := true;
        JobQueueEntry."Run on Thursdays" := true;
        JobQueueEntry."Run on Fridays" := true;
        JobQueueEntry."Run on Saturdays" := true;
        JobQueueEntry."Run on Sundays" := true;
        JobQueueEntry."Maximum No. of Attempts to Run" := 3;
        JobQueueEntry.Insert(true);

        JobQueueEntry.SetStatus(JobQueueEntry.Status::Ready);
    end;
}
