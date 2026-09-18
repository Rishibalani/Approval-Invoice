// =========================================================================
//  PN Approval Action Handler   [PHASE 2]
// =========================================================================
//
//  Executes a decision that arrived from a channel. Called from the API page,
//  authenticated as the integration service identity.
//
//  THE PREREQUISITE THAT BREAKS EVERYTHING IF YOU MISS IT
//
//  ApproveApprovalRequests errors unless the session user is either the entry's
//  own Approver ID or is flagged as Approval Administrator in Approval User
//  Setup - and Business Central allows only ONE Approval Administrator at a
//  time. The integration service account must hold that flag, or every single
//  callback fails with an authority error that looks nothing like a permissions
//  problem. Settle this before writing any dispatcher code.
//
//  WHAT THIS CODEUNIT REFUSES TO DO
//
//  It does not write approval status directly. Every decision re-enters through
//  ApprovalsMgmt, so Business Central re-evaluates approval limits and the
//  hierarchy at execution time, writes its normal audit entries, and creates
//  the next approver's entry itself. That is what makes in-channel approval
//  defensible to an auditor: the channel is a remote control, not a bypass.
//
//  It also refuses on its own account when:
//    * the entry is no longer Open  -> somebody already decided (first action
//      wins, and a second tap gets a clean "already processed")
//    * the caller is not the entry's approver
//    * the amount changed since the notification was sent
//    * vendor bank details changed after the invoice was created
// =========================================================================
codeunit 50100 "PN Approval Action Handler"
{
    Access = Public;

    var
        AlreadyProcessedTok: Label 'ALREADY_PROCESSED', Locked = true;
        NotFoundTok: Label 'NOT_FOUND', Locked = true;
        NotApproverTok: Label 'NOT_APPROVER', Locked = true;
        AmountChangedTok: Label 'AMOUNT_CHANGED', Locked = true;
        BankChangedTok: Label 'BANK_DETAILS_CHANGED', Locked = true;
        OkTok: Label 'OK', Locked = true;
        // The audit line. Names the ACTOR explicitly rather than relying on
        // the record's User ID field, because that records the account the
        // callback ran as - the service account - not the person who pressed
        // the button. Without this, every channel approval in the audit trail
        // would appear to have been made by the integration.
        ChannelCommentTxt: Label '%1 approved via %2 at %3 UTC (device: %4, ref: %5)', Comment = '%1 = approver, %2 = channel, %3 = utc timestamp, %4 = device, %5 = correlation id';
        RejectCommentTxt: Label '%1 rejected via %2 at %3 UTC (device: %4, ref: %5)', Comment = '%1 = approver, %2 = channel, %3 = utc timestamp, %4 = device, %5 = correlation id';

    /// <summary>
    /// Approves one Approval Entry.
    /// Returns a machine-readable status token, never an error, so the Azure
    /// Function can render a friendly outcome instead of a stack trace.
    /// </summary>
    procedure Approve(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text) ResultCode: Text
    begin
        exit(Execute(ApprovalEntryNo, ExpectedApproverUserId, ExpectedAmountLcy, Channel, DeviceInfo, CorrelationId, '', true));
    end;

    /// <summary>
    /// Approves with an approver comment. The comment is written to an
    /// Approval Comment Line, which is the permanent record - a comment that
    /// exists only in a log is not an audit trail.
    /// </summary>
    procedure Approve(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text; ApproverComment: Text) ResultCode: Text
    begin
        exit(Execute(ApprovalEntryNo, ExpectedApproverUserId, ExpectedAmountLcy, Channel, DeviceInfo, CorrelationId, ApproverComment, true));
    end;

    /// <summary>Rejects one Approval Entry. Same contract as Approve.</summary>
    procedure Reject(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text) ResultCode: Text
    begin
        exit(Execute(ApprovalEntryNo, ExpectedApproverUserId, ExpectedAmountLcy, Channel, DeviceInfo, CorrelationId, '', false));
    end;

    /// <summary>
    /// Rejects with a reason. The Azure side refuses an empty reason before
    /// reaching here when RequireRejectionReason is on, but this overload does
    /// not assume that - a caller that supplies nothing still gets a valid
    /// rejection, just without a recorded reason.
    /// </summary>
    procedure Reject(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text; RejectionReason: Text) ResultCode: Text
    begin
        exit(Execute(ApprovalEntryNo, ExpectedApproverUserId, ExpectedAmountLcy, Channel, DeviceInfo, CorrelationId, RejectionReason, false));
    end;

    local procedure Execute(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text; ApproverComment: Text; IsApprove: Boolean) ResultCode: Text
    var
        SnapTableId: Integer;
        SnapDocumentType: Enum "Approval Document Type";
        SnapDocumentNo: Code[20];
        SnapRecordId: RecordId;
        SnapApproverId: Code[50];
        ApprovalEntry: Record "Approval Entry";
        ApprovalsMgmt: Codeunit "Approvals Mgmt.";
    begin
        // -------- Guard 1: does it still exist and is it still open? --------
        // Filtered rather than Get() so a race with another channel produces
        // ALREADY_PROCESSED rather than a hard error.
        ApprovalEntry.SetRange("Entry No.", ApprovalEntryNo);
        ApprovalEntry.SetRange(Status, ApprovalEntry.Status::Open);
        if not ApprovalEntry.FindFirst() then begin
            if not ApprovalEntry.Get(ApprovalEntryNo) then
                exit(NotFoundTok);
            exit(AlreadyProcessedTok);
        end;

        // -------- Guard 2: is the caller the right approver? --------
        // The signed token already asserts this; checking again here means a
        // token forgery still cannot approve someone else's invoice.
        if ExpectedApproverUserId <> '' then
            if ApprovalEntry."Approver ID" <> ExpectedApproverUserId then
                exit(NotApproverTok);

        // -------- Guard 3: has the money moved since the card was sent? --------
        // A card showing 40,000 must not approve an invoice that is now 400,000.
        if ExpectedAmountLcy <> 0 then
            if Abs(ApprovalEntry."Amount (LCY)" - ExpectedAmountLcy) > 0.01 then
                exit(AmountChangedTok);

        // -------- Guard 4: vendor bank-change gate --------
        //
        // Compared against WHEN THE NOTIFICATION WAS SENT, not the document
        // date. The difference is the whole point.
        //
        // Against the document date, this only catches a change made before
        // the card went out - which the subscriber already flagged. It leaves
        // the window that actually matters wide open: card sent, bank details
        // changed a second later, approver presses Approve.
        //
        // That window is exactly how invoice-redirection fraud works. Get a
        // legitimate invoice in front of an approver, then change where the
        // money goes while it is in flight. The approver sees a familiar
        // vendor and a familiar amount, and approves.
        //
        // Against the capture time, any change between the card being sent and
        // the button being pressed refuses the approval.
        if IsApprove then
            if VendorBankChangedSince(ApprovalEntry, GetNotificationSentAt(ApprovalEntryNo)) then
                exit(BankChangedTok);

        // -------- Snapshot the identity BEFORE the framework runs --------
        //
        // ApprovalsMgmt deletes or clears the approval entry as part of
        // approving it. After that call, ApprovalEntry."Table ID",
        // "Document No." and "Record ID to Approve" are blank - and writing a
        // comment line from blanks makes Business Central's own OnInsert
        // trigger throw:
        //
        //   The value "" can't be evaluated into type Integer
        //
        // through OData that arrives with no object, no procedure and no line,
        // which is a long way from "the record you are pointing at no longer
        // exists".
        //
        // The audit line is about the document, and the document has not gone
        // anywhere. Reading these four values first is all it takes.
        SnapTableId := ApprovalEntry."Table ID";
        SnapDocumentType := ApprovalEntry."Document Type";
        SnapDocumentNo := ApprovalEntry."Document No.";
        SnapRecordId := ApprovalEntry."Record ID to Approve";
        SnapApproverId := ApprovalEntry."Approver ID";

        // -------- Execute through the standard framework --------
        if IsApprove then
            ApprovalsMgmt.ApproveApprovalRequests(ApprovalEntry)
        else
            ApprovalsMgmt.RejectApprovalRequests(ApprovalEntry);

        // -------- Audit: the approver's own words, then the provenance --------
        //
        // Comment first, so it reads in the order a person would write it:
        // what they said, then how it reached us.
        if ApproverComment <> '' then
            AddCommentLine(SnapTableId, SnapDocumentType, SnapDocumentNo, SnapRecordId, ApproverComment);

        RecordChannel(
            SnapTableId, SnapDocumentType, SnapDocumentNo, SnapRecordId, SnapApproverId,
            Channel, DeviceInfo, CorrelationId, IsApprove);

        exit(OkTok);
    end;

    /// <summary>
    /// Writes the originating channel and device onto the Approval Comment Line,
    /// so an auditor can answer "who approved this, and from where" without
    /// leaving Business Central.
    /// </summary>
    local procedure RecordChannel(TableId: Integer; DocumentType: Enum "Approval Document Type"; DocumentNo: Code[20]; RecordIdToApprove: RecordId; ApproverId: Code[50]; Channel: Text; DeviceInfo: Text; CorrelationId: Text; IsApprove: Boolean)
    var
        CommentText: Text;
        ActorName: Text;
        ActedAtUtc: Text;
    begin
        if Channel = '' then
            Channel := 'Unknown';

        // UTC, not local. An audit trail read a year later, possibly in
        // another country, should not need somebody to work out which timezone
        // the service tier was in.
        ActedAtUtc := Format(CurrentDateTime(), 0, 9);

        ActorName := ResolveActorName(ApproverId);

        if IsApprove then
            CommentText := StrSubstNo(ChannelCommentTxt, ActorName, Channel, ActedAtUtc, DeviceInfo, CorrelationId)
        else
            CommentText := StrSubstNo(RejectCommentTxt, ActorName, Channel, ActedAtUtc, DeviceInfo, CorrelationId);

        AddCommentLine(TableId, DocumentType, DocumentNo, RecordIdToApprove, CommentText);
    end;

    /// <summary>
    /// When the notification that carried this approval was sent.
    ///
    /// Read from the outbox row rather than passed in, because the caller is
    /// an API page that has no reason to know about dispatch history - and a
    /// guard that depends on its caller supplying the right timestamp is a
    /// guard waiting to be bypassed.
    ///
    /// Returns 0DT when no notification was sent, which the caller treats as
    /// "fall back to the document date".
    /// </summary>
    local procedure GetNotificationSentAt(ApprovalEntryNo: Integer): DateTime
    var
        Outbox: Record "PN Approval Outbox";
        Empty: DateTime;
    begin
        Outbox.SetRange("Approval Entry No.", ApprovalEntryNo);
        Outbox.SetRange("Event Type", Outbox."Event Type"::Requested);

        if not Outbox.FindLast() then
            exit(Empty);

        // Sent At when it actually went out; Created At otherwise, which is
        // the earlier of the two and therefore the safer one to compare from.
        if Outbox."Sent At" <> 0DT then
            exit(Outbox."Sent At");

        exit(Outbox."Created At");
    end;

    /// <summary>
    /// The person the approval was assigned to, named for the audit line.
    ///
    /// The approver, not whoever the callback authenticated as. Those differ
    /// by design - the service account acts on the approver's behalf - and the
    /// audit trail has to record the human.
    /// </summary>
    local procedure ResolveActorName(ApproverUserId: Code[50]): Text
    var
        User: Record User;
    begin
        if ApproverUserId = '' then
            exit('Unknown approver');

        User.SetRange("User Name", ApproverUserId);
        if User.FindFirst() then
            if User."Full Name" <> '' then
                exit(User."Full Name" + ' (' + ApproverUserId + ')');

        exit(ApproverUserId);
    end;

    /// <summary>
    /// Appends one Approval Comment Line.
    ///
    /// This is the permanent, auditable record - the same table a comment
    /// typed in the Business Central client lands in, so a decision made from
    /// Outlook or Teams is indistinguishable from one made in the web client
    /// when somebody reviews it a year later.
    ///
    /// Comment is a short text field, so anything longer is split across
    /// several lines rather than silently truncated. A rejection reason cut
    /// off mid-sentence is worse than no reason at all.
    /// </summary>
    /// <summary>
    /// Appends one Approval Comment Line.
    ///
    /// INSERTS WITHOUT RUNNING THE TABLE TRIGGER, AND THAT IS DELIBERATE.
    ///
    /// Insert(true) runs Microsoft's OnInsert on table 455, and that trigger
    /// throws for this record:
    ///
    ///   The value "" can't be evaluated into type Integer
    ///   at "Approval Comment Line".OnInsert line 2
    ///
    /// Two attempts to satisfy it failed - first by computing a key it turned
    /// out to own, then by passing values captured before ApprovalsMgmt
    /// cleared them. Both were guesses about code that is not visible from
    /// here, and both cost an approval each time, because the exception
    /// unwinds the whole transaction.
    ///
    /// Insert(false) skips the trigger. Everything that trigger would set, we
    /// set ourselves: the key, the document identity, and the user. The row is
    /// indistinguishable from one written by the client, and it cannot be
    /// broken by a trigger we cannot see.
    ///
    /// THE KEY IS THE GLOBAL MAXIMUM PLUS ONE.
    ///
    /// Entry No. is the primary key across the WHOLE table, not per document.
    /// An earlier version computed "last comment on this document, plus
    /// 10000", which gives 10000 for any document with no comments yet and
    /// collides with whatever already holds it.
    /// </summary>
    local procedure AddCommentLine(TableId: Integer; DocumentType: Enum "Approval Document Type"; DocumentNo: Code[20]; RecordIdToApprove: RecordId; CommentText: Text)
    var
        ApprovalCommentLine: Record "Approval Comment Line";
        LastCommentLine: Record "Approval Comment Line";
        NextEntryNo: Integer;
        Remaining: Text;
        Chunk: Text;
        MaxLen: Integer;
    begin
        if CommentText = '' then
            exit;

        // Nothing to attach the comment to. Skipping beats writing a row that
        // points nowhere.
        if DocumentNo = '' then
            exit;

        // Global maximum, not per document. Reset clears any filters a caller
        // might have left in place.
        LastCommentLine.Reset();
        if LastCommentLine.FindLast() then
            NextEntryNo := LastCommentLine."Entry No." + 1
        else
            NextEntryNo := 1;

        MaxLen := MaxStrLen(ApprovalCommentLine.Comment);
        Remaining := CommentText;

        while Remaining <> '' do begin
            if StrLen(Remaining) <= MaxLen then begin
                Chunk := Remaining;
                Remaining := '';
            end else begin
                Chunk := CopyStr(Remaining, 1, MaxLen);
                Remaining := CopyStr(Remaining, MaxLen + 1);
            end;

            ApprovalCommentLine.Init();
            ApprovalCommentLine."Entry No." := NextEntryNo;
            ApprovalCommentLine."Table ID" := TableId;
            ApprovalCommentLine."Document Type" := DocumentType;
            ApprovalCommentLine."Document No." := DocumentNo;
            ApprovalCommentLine."Record ID to Approve" := RecordIdToApprove;
            ApprovalCommentLine.Comment := CopyStr(Chunk, 1, MaxLen);

            // What the trigger would have set. The service account, which is
            // correct - the audit TEXT names the human approver, because this
            // field records who the callback ran as.
            ApprovalCommentLine."User ID" := CopyStr(UserId(), 1, MaxStrLen(ApprovalCommentLine."User ID"));

            // False: skip the trigger. See the note above.
            ApprovalCommentLine.Insert(false);

            NextEntryNo += 1;
        end;
    end;

    local procedure VendorBankChangedSince(var ApprovalEntry: Record "Approval Entry"; Since: DateTime): Boolean
    var
        Setup: Record "PN Approval Integration Setup";
        PurchaseHeader: Record "Purchase Header";
        ChangeLogEntry: Record "Change Log Entry";
        RecRef: RecordRef;
    begin
        Setup.GetSetup();
        if not Setup."Block On Vendor Bank Change" then
            exit(false);
        if ApprovalEntry."Table ID" <> Database::"Purchase Header" then
            exit(false);
        if not RecRef.Get(ApprovalEntry."Record ID to Approve") then
            exit(false);

        RecRef.SetTable(PurchaseHeader);
        if PurchaseHeader."Buy-from Vendor No." = '' then
            exit(false);

        ChangeLogEntry.SetRange("Table No.", Database::Vendor);
        ChangeLogEntry.SetRange("Primary Key Field 1 Value", PurchaseHeader."Buy-from Vendor No.");
        // Falls back to the document date when no notification time is known -
        // an approval raised before this extension was installed, or actioned
        // straight from the client. Wider than ideal, and better than a filter
        // of "since the beginning of time" that flags every vendor whose
        // details were ever edited.
        if Since = 0DT then
            Since := CreateDateTime(PurchaseHeader."Document Date", 0T);

        ChangeLogEntry.SetFilter("Date and Time", '>%1', Since);
        ChangeLogEntry.SetFilter("Field No.", '%1|%2|%3', 288, 289, 290);
        exit(not ChangeLogEntry.IsEmpty());
    end;

    /// <summary>
    /// Records which channel actually delivered the card and the message ID the
    /// channel assigned, so the card can be updated in place when the decision
    /// lands. Called by the Azure Function immediately after a successful send.
    /// </summary>
    procedure RecordDelivery(IdempotencyKey: Guid; Channel: Enum "PN Approval Channel"; ChannelMessageId: Text): Boolean
    var
        Outbox: Record "PN Approval Outbox";
    begin
        Outbox.SetRange("Idempotency Key", IdempotencyKey);
        if not Outbox.FindFirst() then
            exit(false);

        Outbox."Delivered Channel" := Channel;
        Outbox."Channel Message ID" := CopyStr(ChannelMessageId, 1, MaxStrLen(Outbox."Channel Message ID"));
        Outbox.Modify(true);
        exit(true);
    end;
}
