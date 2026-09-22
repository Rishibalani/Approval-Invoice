// =========================================================================
//  PN Approval Email Sender
// =========================================================================
//
//  Composes and sends the Outlook approval email from Business Central, using
//  the platform's own email module.
//
//  WHY THIS MOVED OUT OF AZURE
//
//  Azure used to send this through Microsoft Graph. That worked, and it cost:
//  an app registration, a Global Administrator consent, an Exchange
//  application access policy, a shared mailbox, and four configuration
//  settings - none of which Business Central needs, because it already sends
//  email and has done since the day it was set up.
//
//  Moving it here deletes all of that. The email account is already
//  configured, the permission already granted, and nobody has to justify a
//  tenant-wide Mail.Send grant to a security reviewer.
//
//  WHAT AZURE STILL OWNS
//
//  The buttons. Every link points at the Azure action endpoint carrying a
//  signed token, and Azure still validates the token, burns the nonce,
//  enforces the rejection reason and calls back into Business Central.
//
//  Business Central composes and sends. Azure decides. That line is worth
//  keeping clean - it means a change to approval policy touches one side and a
//  change to email wording touches the other.
//
//  THE ONE THING GIVEN UP
//
//  Actionable Messages. The card lives in a script block in the HTML head, and
//  Business Central's email module strips script tags - so these are plain
//  HTML emails with link buttons rather than buttons that work inside the
//  inbox.
//
//  Tapping a button opens a browser, which lands on the same confirmation page
//  the Teams link mode uses. That is a real difference in polish, and it buys
//  back five pieces of infrastructure. For a fallback channel it is the right
//  trade; Teams is where the good experience lives.
// =========================================================================
codeunit 50107 "PN Approval Email Sender"
{
    Access = Internal;
    Permissions = tabledata "PN Approval Outbox" = rm;

    var
        SubjectTok: Label 'Approval needed: %1 - %2 - %3', Comment = '%1 = document no., %2 = counterparty, %3 = amount';
        NoRecipientErr: Label 'No email address for approver %1. Which field is read depends on the active block in PN User Setup Ext - Block A reads E-Mail on Approval User Setup, Block B reads Authentication Email on the User record.', Comment = '%1 = user id';

    /// <summary>
    /// Sends the approval email for one outbox row.
    ///
    /// Returns false rather than throwing when it cannot send, because a
    /// failed email is a retry rather than an exception - the runner records
    /// it on the row and tries again on the next cycle.
    /// </summary>
    procedure TrySendApprovalEmail(var Outbox: Record "PN Approval Outbox"; var FailureReason: Text): Boolean
    var
        UserSetup: Record "User Setup";
        Setup: Record "PN Approval Integration Setup";
        EmailMessage: Codeunit "Email Message";
        Email: Codeunit Email;
        Recipients: List of [Text];
        RecipientEmail: Text;
        Body: Text;
        Subject: Text;
    begin
        Setup.GetSetup();
        FailureReason := '';

        if not UserSetup.PNGetOrCreate(Outbox."Approver User ID") then begin
            FailureReason := StrSubstNo(NoRecipientErr, Outbox."Approver User ID");
            exit(false);
        end;

        // Suspended means on leave. Their approvals still work inside Business
        // Central; they simply are not chased in a channel.
        if UserSetup."PN Channel Notifications Off" then begin
            FailureReason := 'Channel notifications are suspended for this approver.';
            exit(false);
        end;

        RecipientEmail := UserSetup.PNResolveEmail();

        if RecipientEmail = '' then begin
            FailureReason := StrSubstNo(NoRecipientErr, Outbox."Approver User ID");
            exit(false);
        end;

        Recipients.Add(RecipientEmail);

        Subject := StrSubstNo(SubjectTok,
            Outbox."Document No.",
            GetCounterpartyName(Outbox),
            FormatMoney(Outbox.Amount, Outbox."Currency Code"));

        Body := BuildHtml(Outbox, UserSetup, Setup, RecipientEmail);

        EmailMessage.Create(Recipients, Subject, Body, true);

        // The scenario comes from Email Scenario on setup (Notification by
        // default, not Default). It lets an administrator point approval mail
        // at a different account from, say, posted sales invoices, without
        // touching this code.
        exit(Email.Send(EmailMessage, Setup."Email Scenario"));
    end;

    // ------------------------------------------------------------------
    //  HTML
    // ------------------------------------------------------------------

    /// <summary>
    /// The email body.
    ///
    /// Tables and inline styles throughout, which looks like 2005 web
    /// development because email clients are 2005 web browsers. Outlook renders
    /// HTML with Word's engine: no flexbox, no grid, no external stylesheets,
    /// and unreliable div layout. Tables and inline styles are what survive.
    /// </summary>
    local procedure BuildHtml(var Outbox: Record "PN Approval Outbox"; var UserSetup: Record "User Setup"; var Setup: Record "PN Approval Integration Setup"; RecipientEmail: Text) Html: Text
    var
        TokenMgt: Codeunit "PN Approval Action Token";
        ApprovalEntry: Record "Approval Entry";
        Builder: TextBuilder;
        CanActInChannel: Boolean;
        ApproveUrl: Text;
        RejectUrl: Text;
        DeepLink: Text;
    begin
        CanActInChannel := CanApproveFromEmail(Outbox, UserSetup, Setup);

        if CanActInChannel then begin
            ApproveUrl := TokenMgt.BuildActionUrl(Outbox."Approval Entry No.", RecipientEmail, true);
            RejectUrl := TokenMgt.BuildActionUrl(Outbox."Approval Entry No.", RecipientEmail, false);
        end;

        // Pass the RECORD, not the document number.
        //
        // Given a record, BuildDeepLink uses GetUrl, which produces a proper
        // bookmark link straight to that invoice - correctly encoded, and
        // valid whatever the tenant and environment happen to be. Given a code
        // it falls back to a filter-style link, which works but is more
        // fragile and depends on BC Base URL being set correctly.
        DeepLink := Setup.BuildDeepLink(GetPageIdFor(Outbox), GetDocumentRecord(Outbox));

        Builder.Append('<html><head><meta charset="utf-8"></head>');
        Builder.Append('<body style="margin:0;padding:24px;background:#f5f5f5;');
        Builder.Append('font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#1a1a1a;">');
        Builder.Append('<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">');
        Builder.Append('<table role="presentation" width="580" cellpadding="0" cellspacing="0" ');
        Builder.Append('style="background:#ffffff;border-radius:8px;padding:28px;">');

        // ---- Header ----
        Builder.Append('<tr><td>');
        Builder.Append('<div style="color:#666;font-size:13px;">' + Enc(GetTypeCaption(Outbox)) + '</div>');
        Builder.Append('<div style="font-size:18px;font-weight:600;margin-top:2px;">' +
            Enc(Outbox."Document No.") + ' &middot; ' + Enc(GetCounterpartyName(Outbox)) + '</div>');
        Builder.Append('<div style="font-size:28px;font-weight:600;margin-top:14px;">' +
            Enc(FormatMoney(Outbox.Amount, Outbox."Currency Code")) + '</div>');
        Builder.Append('</td></tr>');

        // ---- Facts ----
        Builder.Append('<tr><td style="padding-top:20px;">');
        Builder.Append('<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;">');

        // Same facts, same order as the Teams and WhatsApp cards. All three
        // are built from the same document, so an approver comparing two
        // channels must not see two different invoices.
        Builder.Append(Row('Document', Outbox."Document No."));
        Builder.Append(Row(CounterpartyLabel(Outbox), ComposeParty(Outbox)));

        if PayToDiffers(Outbox) then
            Builder.Append(Row('Pay-to', PayToName(Outbox)));

        Builder.Append(Row('Their reference', ExternalDocumentNo(Outbox)));

        // Tax breakdown only when there is one. Printing the same number twice
        // under two labels makes the email longer without making it clearer.
        if HasTaxBreakdown(Outbox) then begin
            Builder.Append(Row('Amount excl. tax', FormatMoney(AmountExclTax(Outbox), Outbox."Currency Code")));
            if TaxAmount(Outbox) > 0 then
                Builder.Append(Row('Tax', FormatMoney(TaxAmount(Outbox), Outbox."Currency Code")));
            Builder.Append(Row('Amount incl. tax', FormatMoney(AmountInclTax(Outbox), Outbox."Currency Code")));
        end else
            Builder.Append(Row('Amount', FormatMoney(Outbox.Amount, Outbox."Currency Code")));

        // Only interesting on a foreign-currency document, and that is exactly
        // when an approver needs it.
        if (Outbox."Currency Code" <> '') and (Outbox.Amount <> Outbox."Amount (LCY)") then
            Builder.Append(Row('Local value', FormatMoney(Outbox."Amount (LCY)", '')));

        Builder.Append(Row('Document date', FormatDate(DocumentDate(Outbox))));
        Builder.Append(Row('Posting date', FormatDate(PostingDate(Outbox))));
        Builder.Append(Row('Due date', FormatDate(DueDate(Outbox))));
        Builder.Append(Row('Dimension', DimensionDisplay(1, Dimension1(Outbox))));
        Builder.Append(Row('Cost centre', DimensionDisplay(2, Dimension2(Outbox))));

        if ApprovalEntry.Get(Outbox."Approval Entry No.") then begin
            Builder.Append(Row('Requested by', ResolveUserName(ApprovalEntry."Sender ID")));
            Builder.Append(Row('Submitted', FormatDateTime(ApprovalEntry."Date-Time Sent for Approval")));
        end;

        // "Respond by" removed, matching the Teams card. It duplicated the
        // invoice Due date closely enough to be read as the same thing, and an
        // approver comparing two dates that mean different things is worse
        // served than one shown a single date that matters.

        Builder.Append('</table></td></tr>');

        // ---- Lines ----
        Builder.Append(BuildLinesTable(Outbox, Setup.GetEmailMaxLines()));

        // ---- Chain position ----
        //
        // "Approval 2 of 3" rather than a bare step number. Whether this is
        // the last approval changes what approving MEANS - it either passes
        // the invoice on or releases it - and an approver should not have to
        // open Business Central to find that out.
        Builder.Append(ChainContextRow(Outbox));

        // ---- Warnings, above the buttons ----
        //
        // An approver who has already decided by the time they scroll past the
        // amount will not read a caveat placed underneath it.
        if Outbox."Bank Details Changed" then
            Builder.Append(Warning(
                'This vendor''s bank details changed after the invoice was created. Please review in Business Central before approving.',
                '#a4262c', '#fdf3f4'));

        if Outbox."High Value" then
            Builder.Append(Warning(
                'This invoice is above the value that can be approved from an email. Please open it in Business Central.',
                '#d97706', '#fff4e5'));

        // ---- Buttons ----
        Builder.Append('<tr><td style="padding-top:24px;">');

        if CanActInChannel then begin
            if ApproveUrl <> '' then
                Builder.Append(Button(ApproveUrl, 'Approve', '#107c10'));
            if RejectUrl <> '' then
                Builder.Append(Button(RejectUrl, 'Reject', '#a4262c'));
        end;

        // On every email in every case. When something goes wrong - a stale
        // token, a changed amount, a client that mangles the layout - this is
        // the route that always works.
        if DeepLink <> '' then
            Builder.Append(Button(DeepLink, 'View in Business Central', '#5a5a5a'));

        Builder.Append('</td></tr>');

        if CanActInChannel then begin
            Builder.Append('<tr><td style="padding-top:24px;color:#999;font-size:12px;">');
            Builder.Append('Approval buttons expire ' + Format(Setup.GetActionTokenTtlMinutes()) +
                ' minutes after this was sent. After that, please use Business Central.');
            Builder.Append('</td></tr>');
        end;

        Builder.Append('</table></td></tr></table></body></html>');

        exit(Builder.ToText());
    end;

    // ------------------------------------------------------------------
    //  Policy
    // ------------------------------------------------------------------

    /// <summary>
    /// Whether this approval may be actioned from an email at all.
    ///
    /// The same decision the payload builder makes for Teams and WhatsApp,
    /// applied here because Business Central now owns the email. Financial
    /// policy stays in the system of record either way - it is never inferred
    /// from an amount on the rendering side.
    /// </summary>
    local procedure CanApproveFromEmail(var Outbox: Record "PN Approval Outbox"; var UserSetup: Record "User Setup"; var Setup: Record "PN Approval Integration Setup"): Boolean
    var
        ApprovalEntry: Record "Approval Entry";
        Threshold: Decimal;
    begin
        // Only an open request can be acted on.
        if Outbox."Event Type" <> Outbox."Event Type"::Requested then
            exit(false);

        // A bank-detail change is the single most common payment-fraud signal
        // in accounts payable. Force a signed-in review.
        if Outbox."Bank Details Changed" then
            exit(false);

        if Outbox."High Value" then
            exit(false);

        // The channel ceiling, which is lower for email than for Teams because
        // a link in an inbox proves less about who clicked it.
        if Setup."Outlook Max Approve (LCY)" > 0 then
            if Abs(Outbox."Amount (LCY)") >= Setup."Outlook Max Approve (LCY)" then
                exit(false);

        Threshold := UserSetup.PNEffectiveHighValueThreshold(Setup."High Value Threshold (LCY)");
        if Threshold > 0 then
            if Abs(Outbox."Amount (LCY)") >= Threshold then
                exit(false);

        // THE APPROVER'S OWN LIMIT IS DELIBERATELY NOT CHECKED HERE.
        //
        // An earlier version refused when the amount exceeded the approver's
        // purchase limit, on the assumption that Business Central would reject
        // the approval anyway. It does not.
        //
        // With Approval Limits, Business Central uses each person's limit to
        // BUILD THE CHAIN, not to decide whether they may act. An approver
        // whose limit is 10 looking at an invoice of 60 is not over-reaching -
        // they are step one of three, and their approval passes it upward.
        //
        // The effect of the old check was that Outlook hid the buttons while
        // Teams showed them, for the same invoice and the same person. Same
        // decision, two answers, and the one that looked more cautious was the
        // one that was wrong.

        if not ApprovalEntry.Get(Outbox."Approval Entry No.") then
            exit(false);

        exit(ApprovalEntry.Status = ApprovalEntry.Status::Open);
    end;

    // ------------------------------------------------------------------
    //  Document detail
    //
    //  Each of these reads the live document rather than the outbox row. The
    //  outbox froze the amount and the risk flags at capture time, deliberately
    //  - they are what the policy decision was based on. Everything else is
    //  read fresh so the email shows the invoice as it stands now.
    // ------------------------------------------------------------------

    local procedure GetPurchase(var Outbox: Record "PN Approval Outbox"; var PurchaseHeader: Record "Purchase Header"): Boolean
    var
        RecRef: RecordRef;
    begin
        if Outbox."Table ID" <> Database::"Purchase Header" then
            exit(false);
        if not RecRef.Get(Outbox."Record ID to Approve") then
            exit(false);

        RecRef.SetTable(PurchaseHeader);
        exit(true);
    end;

    local procedure GetSales(var Outbox: Record "PN Approval Outbox"; var SalesHeader: Record "Sales Header"): Boolean
    var
        RecRef: RecordRef;
    begin
        if Outbox."Table ID" <> Database::"Sales Header" then
            exit(false);
        if not RecRef.Get(Outbox."Record ID to Approve") then
            exit(false);

        RecRef.SetTable(SalesHeader);
        exit(true);
    end;

    /// <summary>"Catering Vendor (V00001)" - name and number together.</summary>
    local procedure ComposeParty(var Outbox: Record "PN Approval Outbox"): Text
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(Compose(PurchaseHeader."Buy-from Vendor Name", PurchaseHeader."Buy-from Vendor No."));
        if GetSales(Outbox, SalesHeader) then
            exit(Compose(SalesHeader."Sell-to Customer Name", SalesHeader."Sell-to Customer No."));
        exit('');
    end;

    local procedure PayToName(var Outbox: Record "PN Approval Outbox"): Text
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(Compose(PurchaseHeader."Pay-to Name", PurchaseHeader."Pay-to Vendor No."));
        if GetSales(Outbox, SalesHeader) then
            exit(Compose(SalesHeader."Bill-to Name", SalesHeader."Bill-to Customer No."));
        exit('');
    end;

    /// <summary>
    /// Whether payment goes somewhere other than the party who raised the
    /// invoice. Worth surfacing: it is the commonest payment-redirection
    /// signal in accounts payable, and it is otherwise three clicks deep.
    /// </summary>
    local procedure PayToDiffers(var Outbox: Record "PN Approval Outbox"): Boolean
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(PurchaseHeader."Pay-to Vendor No." <> PurchaseHeader."Buy-from Vendor No.");
        if GetSales(Outbox, SalesHeader) then
            exit(SalesHeader."Bill-to Customer No." <> SalesHeader."Sell-to Customer No.");
        exit(false);
    end;

    local procedure ExternalDocumentNo(var Outbox: Record "PN Approval Outbox"): Text
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(PurchaseHeader."Vendor Invoice No.");
        if GetSales(Outbox, SalesHeader) then
            exit(SalesHeader."External Document No.");
        exit('');
    end;

    local procedure HasTaxBreakdown(var Outbox: Record "PN Approval Outbox"): Boolean
    begin
        exit(AmountInclTax(Outbox) <> AmountExclTax(Outbox));
    end;

    local procedure AmountExclTax(var Outbox: Record "PN Approval Outbox"): Decimal
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then begin
            PurchaseHeader.CalcFields(Amount);
            exit(PurchaseHeader.Amount);
        end;
        if GetSales(Outbox, SalesHeader) then begin
            SalesHeader.CalcFields(Amount);
            exit(SalesHeader.Amount);
        end;
        exit(Outbox.Amount);
    end;

    local procedure AmountInclTax(var Outbox: Record "PN Approval Outbox"): Decimal
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then begin
            PurchaseHeader.CalcFields("Amount Including VAT");
            exit(PurchaseHeader."Amount Including VAT");
        end;
        if GetSales(Outbox, SalesHeader) then begin
            SalesHeader.CalcFields("Amount Including VAT");
            exit(SalesHeader."Amount Including VAT");
        end;
        exit(Outbox.Amount);
    end;

    local procedure TaxAmount(var Outbox: Record "PN Approval Outbox"): Decimal
    begin
        exit(AmountInclTax(Outbox) - AmountExclTax(Outbox));
    end;

    local procedure DocumentDate(var Outbox: Record "PN Approval Outbox"): Date
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(PurchaseHeader."Document Date");
        if GetSales(Outbox, SalesHeader) then
            exit(SalesHeader."Document Date");
        exit(0D);
    end;

    local procedure PostingDate(var Outbox: Record "PN Approval Outbox"): Date
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(PurchaseHeader."Posting Date");
        if GetSales(Outbox, SalesHeader) then
            exit(SalesHeader."Posting Date");
        exit(0D);
    end;

    local procedure DueDate(var Outbox: Record "PN Approval Outbox"): Date
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(PurchaseHeader."Due Date");
        if GetSales(Outbox, SalesHeader) then
            exit(SalesHeader."Due Date");
        exit(0D);
    end;

    local procedure Dimension1(var Outbox: Record "PN Approval Outbox"): Code[20]
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(PurchaseHeader."Shortcut Dimension 1 Code");
        if GetSales(Outbox, SalesHeader) then
            exit(SalesHeader."Shortcut Dimension 1 Code");
        exit('');
    end;

    local procedure Dimension2(var Outbox: Record "PN Approval Outbox"): Code[20]
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
    begin
        if GetPurchase(Outbox, PurchaseHeader) then
            exit(PurchaseHeader."Shortcut Dimension 2 Code");
        if GetSales(Outbox, SalesHeader) then
            exit(SalesHeader."Shortcut Dimension 2 Code");
        exit('');
    end;

    /// <summary>
    /// "MARKETING - Marketing Department". The code alone means nothing to an
    /// approver who does not work with dimensions daily; the name alone is
    /// ambiguous when two dimensions share one.
    /// </summary>
    local procedure DimensionDisplay(DimensionNo: Integer; DimensionCode: Code[20]): Text
    var
        GeneralLedgerSetup: Record "General Ledger Setup";
        DimensionValue: Record "Dimension Value";
        DimensionCodeField: Code[20];
    begin
        if DimensionCode = '' then
            exit('');
        if not GeneralLedgerSetup.Get() then
            exit(DimensionCode);

        if DimensionNo = 1 then
            DimensionCodeField := GeneralLedgerSetup."Shortcut Dimension 1 Code"
        else
            DimensionCodeField := GeneralLedgerSetup."Shortcut Dimension 2 Code";

        if DimensionCodeField = '' then
            exit(DimensionCode);
        if not DimensionValue.Get(DimensionCodeField, DimensionCode) then
            exit(DimensionCode);
        if DimensionValue.Name = '' then
            exit(DimensionCode);

        exit(DimensionCode + ' - ' + DimensionValue.Name);
    end;

    // ------------------------------------------------------------------
    //  Lines
    // ------------------------------------------------------------------

    /// <summary>
    /// The first Email Max Lines lines (setup), with a count of any remainder.
    ///
    /// The default of ten is the cap the Teams card uses, and matching it keeps
    /// the channels honest - an approver who sees eight lines in Teams and twelve in email
    /// has no idea which to trust.
    ///
    /// Blank and comment lines are excluded. They carry no amount and pad the
    /// list with rows an approver has to skip past.
    /// </summary>
    local procedure BuildLinesTable(var Outbox: Record "PN Approval Outbox"; MaxLines: Integer) Html: Text
    var
        PurchaseHeader: Record "Purchase Header";
        PurchaseLine: Record "Purchase Line";
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
        Builder: TextBuilder;
        Shown: Integer;
        Total: Integer;
        CurrencyCode: Code[10];
    begin
        // MaxLines is Email Max Lines on setup; keep it equal to the Teams
        // card cap. Matching matters more than the number: an approver who
        // sees eight lines in Teams and twelve in email has no idea which to
        // trust.
        CurrencyCode := Outbox."Currency Code";

        if GetPurchase(Outbox, PurchaseHeader) then begin
            PurchaseLine.SetRange("Document Type", PurchaseHeader."Document Type");
            PurchaseLine.SetRange("Document No.", PurchaseHeader."No.");
            PurchaseLine.SetFilter(Type, '<>%1', PurchaseLine.Type::" ");
            Total := PurchaseLine.Count();

            if Total = 0 then
                exit('');

            Builder.Append(LinesHeader());

            if PurchaseLine.FindSet() then
                repeat
                    Shown += 1;
                    Builder.Append(LineRow(
                        PurchaseLine.Description,
                        PurchaseLine.Quantity,
                        PurchaseLine."Unit of Measure Code",
                        PurchaseLine."Line Amount",
                        CurrencyCode));
                until (PurchaseLine.Next() = 0) or (Shown >= MaxLines);
        end else
            if GetSales(Outbox, SalesHeader) then begin
                SalesLine.SetRange("Document Type", SalesHeader."Document Type");
                SalesLine.SetRange("Document No.", SalesHeader."No.");
                SalesLine.SetFilter(Type, '<>%1', SalesLine.Type::" ");
                Total := SalesLine.Count();

                if Total = 0 then
                    exit('');

                Builder.Append(LinesHeader());

                if SalesLine.FindSet() then
                    repeat
                        Shown += 1;
                        Builder.Append(LineRow(
                            SalesLine.Description,
                            SalesLine.Quantity,
                            SalesLine."Unit of Measure Code",
                            SalesLine."Line Amount",
                            CurrencyCode));
                    until (SalesLine.Next() = 0) or (Shown >= MaxLines);
            end else
                exit('');

        Builder.Append('</table>');

        if Total > Shown then
            Builder.Append(StrSubstNo(
                '<div style="color:#999;font-size:12px;margin-top:6px;">%1 more line(s). Open in Business Central to see them all.</div>',
                Total - Shown));

        Builder.Append('</td></tr>');
        exit(Builder.ToText());
    end;

    local procedure LinesHeader(): Text
    begin
        exit('<tr><td style="padding-top:20px;">' +
             '<div style="font-size:13px;font-weight:600;margin-bottom:6px;">Lines</div>' +
             '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" ' +
             'style="font-size:13px;border-collapse:collapse;">' +
             '<tr style="color:#666;">' +
             '<td style="padding:4px 0;border-bottom:1px solid #e1e1e1;">Description</td>' +
             '<td style="padding:4px 0;border-bottom:1px solid #e1e1e1;text-align:right;">Qty</td>' +
             '<td style="padding:4px 0 4px 12px;border-bottom:1px solid #e1e1e1;text-align:right;">Amount</td>' +
             '</tr>');
    end;

    local procedure LineRow(Description: Text; Quantity: Decimal; UnitOfMeasure: Code[10]; LineAmount: Decimal; CurrencyCode: Code[10]): Text
    var
        QtyText: Text;
    begin
        QtyText := Format(Quantity, 0, '<Precision,0:5><Standard Format,0>');
        if UnitOfMeasure <> '' then
            QtyText += ' ' + UnitOfMeasure;

        exit('<tr>' +
             '<td style="padding:4px 0;">' + Enc(Description) + '</td>' +
             '<td style="padding:4px 0;text-align:right;white-space:nowrap;">' + Enc(QtyText) + '</td>' +
             '<td style="padding:4px 0 4px 12px;text-align:right;white-space:nowrap;">' +
             Enc(FormatMoney(LineAmount, CurrencyCode)) + '</td></tr>');
    end;

    /// <summary>
    /// "Approval 2 of 3" and what approving means at this step.
    ///
    /// The distinction matters: approving a middle step passes the invoice on,
    /// approving the last one releases it. An approver should not have to open
    /// Business Central to learn which they are about to do.
    /// </summary>
    local procedure ChainContextRow(var Outbox: Record "PN Approval Outbox") Html: Text
    var
        ApprovalEntry: Record "Approval Entry";
        Total: Integer;
        Text: Text;
    begin
        if not ApprovalEntry.Get(Outbox."Approval Entry No.") then
            exit('');

        Total := CountChainSteps(ApprovalEntry);

        if Total <= 1 then
            exit('');

        if Outbox."Sequence No." >= Total then
            Text := StrSubstNo(
                'Approval %1 of %2. This is the final approval - approving releases the invoice.',
                Outbox."Sequence No.", Total)
        else
            Text := StrSubstNo(
                'Approval %1 of %2. Further approval is required after yours.',
                Outbox."Sequence No.", Total);

        exit('<tr><td style="padding-top:16px;color:#666;font-size:13px;">' + Enc(Text) + '</td></tr>');
    end;

    local procedure CountChainSteps(var ApprovalEntry: Record "Approval Entry"): Integer
    var
        Chain: Record "Approval Entry";
    begin
        Chain.SetRange("Table ID", ApprovalEntry."Table ID");
        Chain.SetRange("Document Type", ApprovalEntry."Document Type");
        Chain.SetRange("Document No.", ApprovalEntry."Document No.");
        exit(Chain.Count());
    end;

    local procedure Compose(Name: Text; No: Code[20]): Text
    begin
        if Name = '' then
            exit(No);
        if No = '' then
            exit(Name);
        exit(Name + ' (' + No + ')');
    end;

    /// <summary>
    /// mm/dd/yy, fixed, for every date on the card.
    ///
    /// Format(Value) with no format string renders in the SERVICE TIER's
    /// locale, which is not the approver's and not necessarily the same as
    /// Teams or WhatsApp. An invoice showing 03/09/26 in one channel and
    /// 09/03/26 in another is the kind of discrepancy that makes somebody
    /// distrust all three.
    /// </summary>
    local procedure FormatDate(Value: Date): Text
    begin
        if Value = 0D then
            exit('');
        exit(Format(Value, 0, '<Month,2>/<Day,2>/<Year,2>'));
    end;

    local procedure FormatDateTime(Value: DateTime): Text
    begin
        if Value = 0DT then
            exit('');
        exit(Format(Value, 0, '<Month,2>/<Day,2>/<Year,2> <Hours24,2>:<Minutes,2>'));
    end;

    // ------------------------------------------------------------------
    //  Formatting helpers
    // ------------------------------------------------------------------

    local procedure GetCounterpartyName(var Outbox: Record "PN Approval Outbox"): Text
    var
        PurchaseHeader: Record "Purchase Header";
        SalesHeader: Record "Sales Header";
        RecRef: RecordRef;
    begin
        if not RecRef.Get(Outbox."Record ID to Approve") then
            exit('');

        case Outbox."Table ID" of
            Database::"Purchase Header":
                begin
                    RecRef.SetTable(PurchaseHeader);
                    exit(PurchaseHeader."Buy-from Vendor Name");
                end;
            Database::"Sales Header":
                begin
                    RecRef.SetTable(SalesHeader);
                    exit(SalesHeader."Sell-to Customer Name");
                end;
        end;

        exit('');
    end;

    local procedure CounterpartyLabel(var Outbox: Record "PN Approval Outbox"): Text
    begin
        if Outbox."Table ID" = Database::"Purchase Header" then
            exit('Vendor');
        exit('Customer');
    end;

    local procedure GetTypeCaption(var Outbox: Record "PN Approval Outbox"): Text
    var
        Side: Text;
    begin
        if Outbox."Table ID" = Database::"Purchase Header" then
            Side := 'Purchase'
        else
            Side := 'Sales';

        exit(Side + ' ' + LowerCase(Format(Outbox."Document Type")) + ' approval');
    end;

    /// <summary>
    /// The document record itself, so the platform can build a bookmark link.
    ///
    /// Falls back to the document number when the record cannot be read -
    /// which produces a filter-style link rather than nothing at all.
    /// </summary>
    local procedure GetDocumentRecord(var Outbox: Record "PN Approval Outbox") Result: Variant
    var
        RecRef: RecordRef;
    begin
        if RecRef.Get(Outbox."Record ID to Approve") then begin
            Result := RecRef;
            exit;
        end;

        Result := Outbox."Document No.";
    end;

    local procedure GetPageIdFor(var Outbox: Record "PN Approval Outbox"): Integer
    begin
        if Outbox."Table ID" = Database::"Purchase Header" then
            exit(Page::"Purchase Invoice");
        exit(Page::"Sales Invoice");
    end;

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

    local procedure FormatMoney(Amount: Decimal; CurrencyCode: Code[10]): Text
    var
        GeneralLedgerSetup: Record "General Ledger Setup";
    begin
        if CurrencyCode = '' then
            if GeneralLedgerSetup.Get() then
                CurrencyCode := GeneralLedgerSetup."LCY Code";

        if CurrencyCode = '' then
            exit(Format(Amount, 0, '<Precision,2:2><Standard Format,0>'));

        exit(Format(Amount, 0, '<Precision,2:2><Standard Format,0>') + ' ' + CurrencyCode);
    end;

    local procedure Row(LabelText: Text; Value: Text): Text
    begin
        // Empty rows are skipped rather than shown as a dash. A row reading
        // "Due: -" looks like a fault and costs a line on an email somebody is
        // reading on a phone.
        if Value = '' then
            exit('');

        exit('<tr><td style="padding:4px 0;color:#666;width:150px;vertical-align:top;">' +
             Enc(LabelText) + '</td><td style="padding:4px 0;">' + Enc(Value) + '</td></tr>');
    end;

    local procedure Warning(Text: Text; BorderColour: Text; BackColour: Text): Text
    begin
        exit('<tr><td style="padding-top:16px;">' +
             '<div style="background:' + BackColour + ';border-left:3px solid ' + BorderColour +
             ';padding:12px;font-size:14px;">' + Enc(Text) + '</div></td></tr>');
    end;

    local procedure Button(Url: Text; LabelText: Text; Colour: Text): Text
    begin
        exit('<a href="' + Enc(Url) + '" style="display:inline-block;padding:10px 20px;margin-right:8px;' +
             'background:' + Colour + ';color:#ffffff;text-decoration:none;border-radius:4px;' +
             'font-size:14px;font-weight:600;">' + Enc(LabelText) + '</a>');
    end;

    /// <summary>
    /// HTML-encodes every interpolated value.
    ///
    /// Vendor names come from a table somebody else can write to, and an
    /// unencoded angle bracket is how a broken layout becomes an injected
    /// link. Not hypothetical on a system where vendors are created by users.
    /// </summary>
    local procedure Enc(Value: Text): Text
    begin
        Value := Value.Replace('&', '&amp;');
        Value := Value.Replace('<', '&lt;');
        Value := Value.Replace('>', '&gt;');
        Value := Value.Replace('"', '&quot;');
        exit(Value);
    end;
}
