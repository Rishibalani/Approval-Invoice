// =========================================================================
//  PN Approval Payload Builder
// =========================================================================
//
//  Builds the JSON contract between Business Central and the Azure Function.
//  Kept separate from the HTTP client so the contract can be unit-tested and
//  eyeballed without a network, and so changing the wire format touches one
//  file.
//
//  CONTRACT RULES
//
//  * schemaVersion is first and is mandatory. The Function rejects anything it
//    does not recognise rather than guessing. Bump it on any breaking change.
//  * Data minimisation is a design constraint, not a nicety. The payload
//    carries what an approver needs to decide - counterparty, number, amount,
//    due date - and nothing else. No bank details. No tax identifiers. Line
//    detail only when explicitly switched on.
//  * The Function is told the policy decision (canApproveInChannel), not the
//    inputs to it. Business Central owns the rules; Azure owns the rendering.
//    That keeps financial policy inside the system of record.
// =========================================================================
codeunit 50105 "PN Approval Payload Builder"
{
    Access = Internal;

    var
        SchemaVersionTok: Label '1.0', Locked = true;

    procedure Build(var Outbox: Record "PN Approval Outbox") PayloadText: Text
    var
        Setup: Record "PN Approval Integration Setup";
        Root: JsonObject;
    begin
        Setup.GetSetup();

        Root.Add('schemaVersion', SchemaVersionTok);
        // Names, not captions and not ordinals.
        //
        // Format(enum, 0, 9) returns the ordinal, which shifts if anyone
        // inserts a value into the enum. Format(enum) returns the caption,
        // which is display text and changes under translation. Neither is a
        // stable wire contract, and BOTH have already broken this integration
        // once - the Azure side compares against these exact strings.
        Root.Add('eventType', GetEventTypeName(Outbox."Event Type"));
        Root.Add('eventId', Format(Outbox."Idempotency Key", 0, 4));
        Root.Add('correlationId', Format(Outbox."Correlation ID", 0, 4));
        Root.Add('occurredUtc', FormatUtc(Outbox."Created At"));

        Root.Add('source', BuildSource(Setup));
        Root.Add('approval', BuildApproval(Outbox));
        Root.Add('document', BuildDocument(Outbox, Setup));
        Root.Add('approver', BuildApprover(Outbox, Setup));
        Root.Add('policy', BuildPolicy(Outbox, Setup));

        Root.WriteTo(PayloadText);
    end;

    // ------------------------------------------------------------------
    //  Where this came from. The Function uses tenantId + environment to
    //  refuse cross-environment traffic, so a sandbox can never post a real
    //  approval card to a production Teams channel.
    // ------------------------------------------------------------------
    local procedure BuildSource(var Setup: Record "PN Approval Integration Setup") Source: JsonObject
    begin
        Source.Add('system', 'BusinessCentral');
        Source.Add('tenantId', Format(Database.TenantId()));
        Source.Add('environment', Setup."Environment Tag");
        Source.Add('companyName', CompanyName());
        Source.Add('companyId', Format(GetCompanyId(), 0, 4));
    end;

    local procedure BuildApproval(var Outbox: Record "PN Approval Outbox") Approval: JsonObject
    var
        ApprovalEntry: Record "Approval Entry";
        OpenEntries: Record "Approval Entry";
    begin
        Approval.Add('approvalEntryNo', Outbox."Approval Entry No.");
        Approval.Add('sequenceNo', Outbox."Sequence No.");
        Approval.Add('recordId', Format(Outbox."Record ID to Approve"));

        if ApprovalEntry.Get(Outbox."Approval Entry No.") then begin
            Approval.Add('status', Format(ApprovalEntry.Status));
            Approval.Add('dueDate', FormatDate(ApprovalEntry."Due Date"));
            Approval.Add('createdOnUtc', FormatUtc(ApprovalEntry."Last Date-Time Modified"));
            Approval.Add('sentForApprovalOn', FormatUtc(ApprovalEntry."Date-Time Sent for Approval"));

            // Who asked for this. An approver can tell at a glance whether the
            // request came from somebody they expect - a weak control, but a
            // free one, and its absence was the blank field on the card.
            Approval.Add('requestedBy', ApprovalEntry."Sender ID");
            Approval.Add('requestedByName', ResolveUserName(ApprovalEntry."Sender ID"));
            Approval.Add('requestedByEmail', ResolveUserEmail(ApprovalEntry."Sender ID"));

            // Multi-level context. The card can honestly say "step 2 of 3"
            // instead of pretending every approval is the last one.
            OpenEntries.SetRange("Table ID", ApprovalEntry."Table ID");
            OpenEntries.SetRange("Document Type", ApprovalEntry."Document Type");
            OpenEntries.SetRange("Document No.", ApprovalEntry."Document No.");
            Approval.Add('totalStepsInChain', OpenEntries.Count());

            OpenEntries.SetRange(Status, OpenEntries.Status::Open);
            Approval.Add('openStepsRemaining', OpenEntries.Count());
            Approval.Add('isFinalStep', OpenEntries.Count() <= 1);
        end else
            Approval.Add('status', 'Unknown');
    end;

    // ------------------------------------------------------------------
    //  Document facts. Reads the live header so a card shows current data,
    //  falling back to the values frozen on the outbox row if the document
    //  has since been posted or deleted.
    // ------------------------------------------------------------------
    local procedure BuildDocument(var Outbox: Record "PN Approval Outbox"; var Setup: Record "PN Approval Integration Setup") Doc: JsonObject
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
        RecRef: RecordRef;
        Found: Boolean;
    begin
        Doc.Add('tableId', Outbox."Table ID");
        Doc.Add('documentType', Format(Outbox."Document Type"));
        Doc.Add('documentNo', Outbox."Document No.");
        Doc.Add('amount', Outbox.Amount);
        Doc.Add('amountLcy', Outbox."Amount (LCY)");
        Doc.Add('currencyCode', Outbox."Currency Code");

        Found := RecRef.Get(Outbox."Record ID to Approve");

        case Outbox."Table ID" of
            Database::"Purchase Header":
                begin
                    Doc.Add('direction', 'Payable');
                    if Found then begin
                        RecRef.SetTable(PurchaseHeader);
                        Doc.Add('counterpartyNo', PurchaseHeader."Buy-from Vendor No.");
                        Doc.Add('counterpartyName', PurchaseHeader."Buy-from Vendor Name");
                        Doc.Add('externalDocumentNo', PurchaseHeader."Vendor Invoice No.");
                        Doc.Add('documentDate', FormatDate(PurchaseHeader."Document Date"));
                        Doc.Add('dueDate', FormatDate(PurchaseHeader."Due Date"));
                        Doc.Add('postingDate', FormatDate(PurchaseHeader."Posting Date"));

                        // Pay-to can differ from Buy-from, and a mismatch is a
                        // payment-redirection signal worth putting in front of
                        // the approver rather than leaving buried in the record.
                        Doc.Add('payToNo', PurchaseHeader."Pay-to Vendor No.");
                        Doc.Add('payToName', PurchaseHeader."Pay-to Name");
                        Doc.Add('payToDiffers',
                            PurchaseHeader."Pay-to Vendor No." <> PurchaseHeader."Buy-from Vendor No.");

                        // Amount and Amount Including VAT are FlowFields. They
                        // read as zero until calculated, which is exactly how a
                        // card ends up showing a blank total.
                        PurchaseHeader.CalcFields(Amount, "Amount Including VAT");
                        Doc.Add('amountExclTax', PurchaseHeader.Amount);
                        Doc.Add('amountInclTax', PurchaseHeader."Amount Including VAT");
                        Doc.Add('deepLink', Setup.BuildDeepLink(Page::"Purchase Invoice", PurchaseHeader));
                        if Setup."Include Document Lines" then
                            Doc.Add('lines', BuildPurchaseLines(PurchaseHeader));
                    end;
                end;
            Database::"Sales Header":
                begin
                    Doc.Add('direction', 'Receivable');
                    if Found then begin
                        RecRef.SetTable(SalesHeader);
                        Doc.Add('counterpartyNo', SalesHeader."Sell-to Customer No.");
                        Doc.Add('counterpartyName', SalesHeader."Sell-to Customer Name");
                        Doc.Add('externalDocumentNo', SalesHeader."External Document No.");
                        Doc.Add('documentDate', FormatDate(SalesHeader."Document Date"));
                        Doc.Add('dueDate', FormatDate(SalesHeader."Due Date"));
                        Doc.Add('postingDate', FormatDate(SalesHeader."Posting Date"));

                        Doc.Add('payToNo', SalesHeader."Bill-to Customer No.");
                        Doc.Add('payToName', SalesHeader."Bill-to Name");
                        Doc.Add('payToDiffers',
                            SalesHeader."Bill-to Customer No." <> SalesHeader."Sell-to Customer No.");

                        SalesHeader.CalcFields(Amount, "Amount Including VAT");
                        Doc.Add('amountExclTax', SalesHeader.Amount);
                        Doc.Add('amountInclTax', SalesHeader."Amount Including VAT");
                        Doc.Add('deepLink', Setup.BuildDeepLink(Page::"Sales Invoice", SalesHeader));
                        if Setup."Include Document Lines" then
                            Doc.Add('lines', BuildSalesLines(SalesHeader));
                    end;
                end;
        end;

        Doc.Add('documentFound', Found);
    end;

    local procedure BuildPurchaseLines(var PurchaseHeader: Record "Purchase Header") Lines: JsonArray
    var
        PurchaseLine: Record "Purchase Line";
        Line: JsonObject;
    begin
        PurchaseLine.SetRange("Document Type", PurchaseHeader."Document Type");
        PurchaseLine.SetRange("Document No.", PurchaseHeader."No.");
        PurchaseLine.SetFilter(Type, '<>%1', PurchaseLine.Type::" ");
        if PurchaseLine.FindSet() then
            repeat
                Clear(Line);
                Line.Add('lineNo', PurchaseLine."Line No.");
                Line.Add('description', PurchaseLine.Description);
                Line.Add('quantity', PurchaseLine.Quantity);
                Line.Add('unitCost', PurchaseLine."Direct Unit Cost");
                Line.Add('lineAmount', PurchaseLine."Line Amount");
                Lines.Add(Line);
            until (PurchaseLine.Next() = 0) or (Lines.Count() >= 20);
    end;

    local procedure BuildSalesLines(var SalesHeader: Record "Sales Header") Lines: JsonArray
    var
        SalesLine: Record "Sales Line";
        Line: JsonObject;
    begin
        SalesLine.SetRange("Document Type", SalesHeader."Document Type");
        SalesLine.SetRange("Document No.", SalesHeader."No.");
        SalesLine.SetFilter(Type, '<>%1', SalesLine.Type::" ");
        if SalesLine.FindSet() then
            repeat
                Clear(Line);
                Line.Add('lineNo', SalesLine."Line No.");
                Line.Add('description', SalesLine.Description);
                Line.Add('quantity', SalesLine.Quantity);
                Line.Add('unitPrice', SalesLine."Unit Price");
                Line.Add('lineAmount', SalesLine."Line Amount");
                Lines.Add(Line);
            until (SalesLine.Next() = 0) or (Lines.Count() >= 20);
    end;

    // ------------------------------------------------------------------
    //  Who to deliver to, and on which channels.
    // ------------------------------------------------------------------
    local procedure BuildApprover(var Outbox: Record "PN Approval Outbox"; var Setup: Record "PN Approval Integration Setup") Approver: JsonObject
    var
        Identity: Record "PN Approver Channel Identity";
        Channels: JsonArray;
        ChannelName: Text;
        HasIdentity: Boolean;
        IsSuspended: Boolean;
        UserSetup: Record "User Setup";
    begin
        Approver.Add('userId', Outbox."Approver User ID");
        Approver.Add('userSecurityId', Format(Outbox."Approver User Security ID", 0, 4));

        HasIdentity := Identity.Get(Outbox."Approver User Security ID");
        if not HasIdentity then
            HasIdentity := Identity.GetOrCreate(Outbox."Approver User Security ID");

        if HasIdentity then begin
            Approver.Add('displayName', Identity."Full Name");
            // ResolveEmail walks User first, then Employee. Invoice approvers
            // often have no Employee record at all, so the User table is the
            // source and Employee is only a fallback.
            Approver.Add('upn', Identity.ResolveEmail());
                        // User Setup is the source of truth for the Entra object ID - it is
            // where approver configuration is already maintained. The identity
            // row keeps a cached copy, used only when User Setup has none.
            if UserSetup.Get(Outbox."Approver User ID") and not IsNullGuid(UserSetup."PN Entra Object ID") then
                Approver.Add('entraObjectId', Format(UserSetup."PN Entra Object ID", 0, 4))
            else
                if not IsNullGuid(Identity."Entra Object ID") then
                    Approver.Add('entraObjectId', Format(Identity."Entra Object ID", 0, 4));
            IsSuspended := Identity.Suspended;
        end else begin
            // No identity row and no User record. The Function routes to the
            // fallback and raises an operational alert rather than dropping it.
            Approver.Add('displayName', Outbox."Approver User ID");
        end;

        Approver.Add('suspended', IsSuspended);

        // Fallback is global too. One setting, one place to change it.
        Approver.Add('fallbackChannel', Format(Setup."Global Fallback Channel"));

        // ---------------------------------------------------------------
        //  Channels come from the GLOBAL toggles on Approval Channel Setup,
        //  never from this approver. Business Central owns this decision
        //  entirely: the Azure Function sends to exactly the channels named
        //  here and has no way to add one that is not.
        //
        //  Suspension is the only per-person override, and it removes every
        //  channel rather than any particular one - someone on leave should
        //  be chased nowhere, not chased somewhere else.
        // ---------------------------------------------------------------
        if not IsSuspended then
            foreach ChannelName in Setup.GetEnabledChannels() do
                Channels.Add(ChannelName);

        Approver.Add('channels', Channels);
    end;

    // ------------------------------------------------------------------
    //  The policy decision, already made. Azure renders; it does not decide.
    // ------------------------------------------------------------------
    local procedure BuildPolicy(var Outbox: Record "PN Approval Outbox"; var Setup: Record "PN Approval Integration Setup") Policy: JsonObject
    var
        Identity: Record "PN Approver Channel Identity";
        Reasons: JsonArray;
        CanApproveInChannel: Boolean;
    begin
        CanApproveInChannel := true;

        if Outbox."High Value" then begin
            CanApproveInChannel := false;
            Reasons.Add('HighValue');
        end;

        if Outbox."Bank Details Changed" then begin
            CanApproveInChannel := false;
            Reasons.Add('VendorBankDetailsChanged');
        end;

        if Identity.Get(Outbox."Approver User Security ID") then
            if Identity.Suspended then begin
                CanApproveInChannel := false;
                Reasons.Add('ApproverSuspended');
            end;

        if Outbox."Event Type" <> Outbox."Event Type"::Requested then begin
            CanApproveInChannel := false;
            Reasons.Add('NotAnOpenRequest');
        end;

        Policy.Add('canApproveInChannel', CanApproveInChannel);
        Policy.Add('suppressionReasons', Reasons);
        Policy.Add('highValue', Outbox."High Value");
        Policy.Add('bankDetailsChanged', Outbox."Bank Details Changed");
        Policy.Add('actionTokenTtlMinutes', 30);
        Policy.Add('requiresSignedInApproval', not CanApproveInChannel);
    end;

    // ------------------------------------------------------------------
    //  Formatting helpers. Everything on the wire is ISO 8601 UTC or a plain
    //  yyyy-MM-dd date; nothing is locale-dependent.
    // ------------------------------------------------------------------
    local procedure FormatUtc(Value: DateTime): Text
    begin
        if Value = 0DT then
            exit('');
        exit(Format(Value, 0, 9));
    end;

    local procedure FormatDate(Value: Date): Text
    begin
        if Value = 0D then
            exit('');
        exit(Format(Value, 0, '<Year4>-<Month,2>-<Day,2>'));
    end;

    /// <summary>
    /// The stable wire name for an event type. Written out explicitly so it
    /// survives renumbering, reordering, translation, and a file being
    /// reverted - all of which have happened.
    /// </summary>
    local procedure GetEventTypeName(EventType: Enum "PN Approval Event Type"): Text
    begin
        case EventType of
            EventType::Requested:
                exit('Requested');
            EventType::Approved:
                exit('Approved');
            EventType::Rejected:
                exit('Rejected');
            EventType::Cancelled:
                exit('Cancelled');
        end;

        exit('Unknown');
    end;

    /// <summary>Display name for a Business Central user name, falling back to the ID.</summary>
    local procedure ResolveUserName(UserName: Code[50]): Text
    var
        User: Record User;
    begin
        if UserName = '' then
            exit('');

        User.SetRange("User Name", UserName);
        if User.FindFirst() then
            if User."Full Name" <> '' then
                exit(User."Full Name");

        exit(UserName);
    end;

    local procedure ResolveUserEmail(UserName: Code[50]): Text
    var
        User: Record User;
    begin
        if UserName = '' then
            exit('');

        User.SetRange("User Name", UserName);
        if User.FindFirst() then
            exit(User."Authentication Email");

        exit('');
    end;

    local procedure GetCompanyId(): Guid
    var
        Company: Record Company;
    begin
        if Company.Get(CompanyName()) then
            exit(Company.Id);
    end;
}
