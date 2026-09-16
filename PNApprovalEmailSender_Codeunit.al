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
        NoRecipientErr: Label 'No email address for approver %1. Check Authentication Email on their Business Central user record.', Comment = '%1 = user id';

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

        // The Notification scenario, not Default. It lets an administrator
        // point approval mail at a different account from, say, posted sales
        // invoices, without touching this code.
        exit(Email.Send(EmailMessage, Enum::"Email Scenario"::Notification));
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

        Builder.Append(Row('Document', Outbox."Document No."));
        Builder.Append(Row(CounterpartyLabel(Outbox), GetCounterpartyName(Outbox)));
        Builder.Append(Row('Amount', FormatMoney(Outbox.Amount, Outbox."Currency Code")));

        if Outbox.Amount <> Outbox."Amount (LCY)" then
            Builder.Append(Row('Local value', FormatMoney(Outbox."Amount (LCY)", '')));

        if ApprovalEntry.Get(Outbox."Approval Entry No.") then begin
            if ApprovalEntry."Due Date" <> 0D then
                Builder.Append(Row('Respond by', Format(ApprovalEntry."Due Date")));

            Builder.Append(Row('Requested by', ResolveUserName(ApprovalEntry."Sender ID")));
        end;

        Builder.Append(Row('Approval step', Format(Outbox."Sequence No.")));
        Builder.Append('</table></td></tr>');

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
            Builder.Append('Approval buttons expire ' + Format(Setup."Action Token TTL (Min.)") +
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

        // The approver's own limit. Business Central would refuse the approval
        // anyway, through ApprovalsMgmt - so this check is purely cosmetic.
        // Showing a button that errors the moment it is pressed looks like a
        // bug, and an approver who hits that twice stops trusting the whole
        // channel.
        if not ApproverLimitAllows(UserSetup, Outbox) then
            exit(false);

        if not ApprovalEntry.Get(Outbox."Approval Entry No.") then
            exit(false);

        exit(ApprovalEntry.Status = ApprovalEntry.Status::Open);
    end;

    /// <summary>
    /// Whether this approver's own limit covers the amount.
    ///
    /// User Setup holds SEPARATE limits for sales, purchase, expense and
    /// requests, each with its own unlimited flag. Picking the wrong pair is
    /// not a compile error and not a runtime error - it silently applies
    /// somebody's sales limit to a purchase invoice, which is the kind of
    /// wrong that survives testing.
    ///
    /// Purchase documents use the purchase pair; sales documents the sales
    /// pair. Anything else is allowed through, because Business Central will
    /// make the real decision regardless and guessing here helps nobody.
    /// </summary>
    local procedure ApproverLimitAllows(var UserSetup: Record "User Setup"; var Outbox: Record "PN Approval Outbox"): Boolean
    var
        Unlimited: Boolean;
        Limit: Decimal;
    begin
        case Outbox."Table ID" of
            Database::"Purchase Header":
                begin
                    Unlimited := UserSetup."Unlimited Purchase Approval";
                    Limit := UserSetup."Purchase Amount Approval Limit";
                end;
            Database::"Sales Header":
                begin
                    Unlimited := UserSetup."Unlimited Sales Approval";
                    Limit := UserSetup."Sales Amount Approval Limit";
                end;
            else
                exit(true);
        end;

        if Unlimited then
            exit(true);

        // Zero means no limit configured, not a limit of zero. That is Business
        // Central's own convention and reversing it here would block every
        // approver who has not had a limit set.
        if Limit = 0 then
            exit(true);

        exit(Abs(Outbox."Amount (LCY)") <= Limit);
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
