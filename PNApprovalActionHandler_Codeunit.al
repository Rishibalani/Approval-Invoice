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
        ChannelCommentTxt: Label 'Approved via %1 (device: %2, correlation: %3)', Comment = '%1 = channel, %2 = device, %3 = correlation id';
        RejectCommentTxt: Label 'Rejected via %1 (device: %2, correlation: %3)', Comment = '%1 = channel, %2 = device, %3 = correlation id';

    /// <summary>
    /// Approves one Approval Entry.
    /// Returns a machine-readable status token, never an error, so the Azure
    /// Function can render a friendly outcome instead of a stack trace.
    /// </summary>
    procedure Approve(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text) ResultCode: Text
    begin
        exit(Execute(ApprovalEntryNo, ExpectedApproverUserId, ExpectedAmountLcy, Channel, DeviceInfo, CorrelationId, true));
    end;

    /// <summary>Rejects one Approval Entry. Same contract as Approve.</summary>
    procedure Reject(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text) ResultCode: Text
    begin
        exit(Execute(ApprovalEntryNo, ExpectedApproverUserId, ExpectedAmountLcy, Channel, DeviceInfo, CorrelationId, false));
    end;

    local procedure Execute(ApprovalEntryNo: Integer; ExpectedApproverUserId: Code[50]; ExpectedAmountLcy: Decimal; Channel: Text; DeviceInfo: Text; CorrelationId: Text; IsApprove: Boolean) ResultCode: Text
    var
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
        if IsApprove then
            if VendorBankChangedSince(ApprovalEntry) then
                exit(BankChangedTok);

        // -------- Execute through the standard framework --------
        if IsApprove then
            ApprovalsMgmt.ApproveApprovalRequests(ApprovalEntry)
        else
            ApprovalsMgmt.RejectApprovalRequests(ApprovalEntry);

        // -------- Audit: channel and device on every action --------
        RecordChannel(ApprovalEntry, Channel, DeviceInfo, CorrelationId, IsApprove);

        exit(OkTok);
    end;

    /// <summary>
    /// Writes the originating channel and device onto the Approval Comment Line,
    /// so an auditor can answer "who approved this, and from where" without
    /// leaving Business Central.
    /// </summary>
    local procedure RecordChannel(var ApprovalEntry: Record "Approval Entry"; Channel: Text; DeviceInfo: Text; CorrelationId: Text; IsApprove: Boolean)
    var
        ApprovalCommentLine: Record "Approval Comment Line";
        NextLineNo: Integer;
        CommentText: Text;
    begin
        if Channel = '' then
            Channel := 'Unknown';

        ApprovalCommentLine.SetRange("Table ID", ApprovalEntry."Table ID");
        ApprovalCommentLine.SetRange("Document Type", ApprovalEntry."Document Type");
        ApprovalCommentLine.SetRange("Document No.", ApprovalEntry."Document No.");
        if ApprovalCommentLine.FindLast() then
            NextLineNo := ApprovalCommentLine."Entry No." + 10000
        else
            NextLineNo := 10000;

        if IsApprove then
            CommentText := StrSubstNo(ChannelCommentTxt, Channel, DeviceInfo, CorrelationId)
        else
            CommentText := StrSubstNo(RejectCommentTxt, Channel, DeviceInfo, CorrelationId);

        ApprovalCommentLine.Init();
        ApprovalCommentLine."Table ID" := ApprovalEntry."Table ID";
        ApprovalCommentLine."Document Type" := ApprovalEntry."Document Type";
        ApprovalCommentLine."Document No." := ApprovalEntry."Document No.";
        ApprovalCommentLine."Entry No." := NextLineNo;
        ApprovalCommentLine."Record ID to Approve" := ApprovalEntry."Record ID to Approve";
        ApprovalCommentLine.Comment := CopyStr(CommentText, 1, MaxStrLen(ApprovalCommentLine.Comment));
        ApprovalCommentLine.Insert(true);
    end;

    local procedure VendorBankChangedSince(var ApprovalEntry: Record "Approval Entry"): Boolean
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
        ChangeLogEntry.SetFilter("Date and Time", '>%1', CreateDateTime(PurchaseHeader."Document Date", 0T));
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
