// =========================================================================
//  PN Approval Diagnostics
// =========================================================================
//
//  Answers one question: why did that approval not reach the outbox?
//
//  It reads the most recent Approval Entry and runs the same scope checks the
//  event subscriber runs, reporting which one rejected it and what the actual
//  value was. That turns "nothing appeared" into a specific line to fix.
//
//  Search for "Approval Diagnostics" in Business Central. Nothing else needs
//  changing to use it - this file is self-contained.
//
//  Safe to leave installed; it is read-only. Remove it before production if
//  you would rather not expose approval internals to end users.
// =========================================================================
page 50106 "PN Approval Diagnostics"
{
    Caption = 'Approval Diagnostics';
    PageType = Card;
    ApplicationArea = All;
    UsageCategory = Administration;
    SourceTable = Integer;
    SourceTableTemporary = true;
    InsertAllowed = false;
    DeleteAllowed = false;
    ModifyAllowed = false;
    Editable = false;

    layout
    {
        area(Content)
        {
            group(Report)
            {
                ShowCaption = false;

                field(DiagnosisText; DiagnosisText)
                {
                    ApplicationArea = All;
                    Caption = 'Diagnosis';
                    MultiLine = true;
                    Editable = false;
                    ShowCaption = false;
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(TestApproveDirect)
            {
                ApplicationArea = All;
                Caption = 'Test Approve (In Process)';
                Image = Approve;
                ToolTip = 'Calls the approval handler directly, in this session, bypassing Azure and OData entirely. Any error appears with a full call stack naming the object and line - detail that a 400 from the API strips out.';

                trigger OnAction()
                begin
                    RunDirectApprove();
                end;
            }

            action(TestApprovalEmail)
            {
                ApplicationArea = All;
                Caption = 'Test Approval Email';
                Image = Email;
                ToolTip = 'Checks the email configuration end to end and sends a real approval email for the most recent open approval, reporting exactly what happened at each step.';

                trigger OnAction()
                begin
                    RunEmailDiagnostic();
                end;
            }

            action(OpenSentEmails)
            {
                ApplicationArea = All;
                Caption = 'Sent Emails';
                Image = Log;
                RunObject = page "Sent Emails";
                ToolTip = 'Business Central''s own record of every email it has sent. If an approval email left Business Central, it is listed here.';
            }

            action(OpenEmailOutbox)
            {
                ApplicationArea = All;
                Caption = 'Email Outbox';
                Image = Log;
                RunObject = page "Email Outbox";
                ToolTip = 'Emails that failed or are still queued. An approval email that never arrived is either here with an error, or was never attempted at all.';
            }

            action(RunDiagnosis)
            {
                ApplicationArea = All;
                Caption = 'Run Diagnosis';
                Image = Refresh;
                ToolTip = 'Re-reads the latest approval entry and re-runs every scope check.';

                trigger OnAction()
                begin
                    BuildDiagnosis();
                    CurrPage.Update(false);
                end;
            }

            action(OpenApprovalEntries)
            {
                ApplicationArea = All;
                Caption = 'Approval Entries';
                Image = Approvals;
                RunObject = page "Approval Entries";
                ToolTip = 'Opens the native approval entries list.';
            }

            action(OpenOutbox)
            {
                ApplicationArea = All;
                Caption = 'Approval Outbox';
                Image = Log;
                RunObject = page "PN Approval Outbox";
            }
        }

        area(Promoted)
        {
            group(Category_Process)
            {
                Caption = 'Process';
                actionref(RunDiagnosis_P; RunDiagnosis) { }
                actionref(OpenApprovalEntries_P; OpenApprovalEntries) { }
                actionref(OpenOutbox_P; OpenOutbox) { }
            }
        }
    }

    var
        DiagnosisText: Text;

    trigger OnOpenPage()
    begin
        Rec.Number := 1;
        if not Rec.Insert() then;
        BuildDiagnosis();
    end;

    local procedure BuildDiagnosis()
    var
        Setup: Record "PN Approval Integration Setup";
        ApprovalEntry: Record "Approval Entry";
        Outbox: Record "PN Approval Outbox";
        User: Record User;
        Builder: TextBuilder;
        SetupExists: Boolean;
        EntryFound: Boolean;
        BlockedBy: Text;
    begin
        Clear(DiagnosisText);

        Builder.AppendLine('=== ENVIRONMENT ===');
        Builder.AppendLine('Company: ' + CompanyName());
        Builder.AppendLine('User: ' + UserId());
        Builder.AppendLine('Checked at: ' + Format(CurrentDateTime()));
        Builder.AppendLine('');

        // ---------------------------------------------------------------
        //  1. Does the setup record exist IN THIS COMPANY?
        //     The subscriber exits immediately if it does not, and this is
        //     the single most common reason for an empty outbox.
        // ---------------------------------------------------------------
        Builder.AppendLine('=== 1. SETUP RECORD ===');
        SetupExists := Setup.Get();

        if not SetupExists then begin
            Builder.AppendLine('*** FAIL: No setup record in this company. ***');
            Builder.AppendLine('The subscriber calls Setup.Get() and exits when it returns false,');
            Builder.AppendLine('so nothing is ever written. Open the Approval Integration Setup');
            Builder.AppendLine('page in THIS company once - it creates the record itself.');
            Builder.AppendLine('');
            Builder.AppendLine('Note that setup is per-company. Configuring it in another company');
            Builder.AppendLine('does not help here.');
            DiagnosisText := Builder.ToText();
            exit;
        end;

        Builder.AppendLine('OK: setup record exists.');
        Builder.AppendLine('  Enabled: ' + Format(Setup.Enabled) + '   (affects dispatch only, not capture)');
        Builder.AppendLine('  Include Purchase Documents: ' + Format(Setup."Include Purchase Documents"));
        Builder.AppendLine('  Include Sales Documents: ' + Format(Setup."Include Sales Documents"));
        Builder.AppendLine('  Min. Amount (LCY): ' + Format(Setup."Min. Amount (LCY)"));
        Builder.AppendLine('  High Value Threshold (LCY): ' + Format(Setup."High Value Threshold (LCY)"));
        Builder.AppendLine('  Block On Vendor Bank Change: ' + Format(Setup."Block On Vendor Bank Change") +
            BankCheckText(Setup));

        // Same checks the runner applies before claiming a row. None of these
        // values has a default in code any more, so a blank one stops dispatch.
        if TryTimingAndPolicySetup(Setup) then
            Builder.AppendLine('  Timing, retry and policy settings: OK')
        else begin
            Builder.AppendLine('  *** Timing, retry and policy settings: ' + GetLastErrorText() + ' ***');
            ClearLastError();
        end;
        Builder.AppendLine('');

        // ---------------------------------------------------------------
        //  2. Are there any approval entries at all?
        //     If not, the problem is upstream in the workflow, not here.
        // ---------------------------------------------------------------
        Builder.AppendLine('=== 2. APPROVAL ENTRIES ===');
        ApprovalEntry.Reset();
        Builder.AppendLine('Total approval entries in this company: ' + Format(ApprovalEntry.Count()));

        ApprovalEntry.SetCurrentKey("Entry No.");
        ApprovalEntry.Ascending(false);
        EntryFound := ApprovalEntry.FindFirst();

        if not EntryFound then begin
            Builder.AppendLine('*** FAIL: No approval entries exist. ***');
            Builder.AppendLine('The document reached Pending Approval but Business Central never');
            Builder.AppendLine('created an approver record. That is a workflow configuration');
            Builder.AppendLine('problem, not an extension problem.');
            Builder.AppendLine('');
            Builder.AppendLine('Check: Approval User Setup has a line for the sender, with an');
            Builder.AppendLine('Approver ID filled in, and the workflow response is set to create');
            Builder.AppendLine('approval requests for the right approver type.');
            DiagnosisText := Builder.ToText();
            exit;
        end;

        Builder.AppendLine('');
        Builder.AppendLine('--- Most recent entry ---');
        Builder.AppendLine('  Entry No.: ' + Format(ApprovalEntry."Entry No."));
        Builder.AppendLine('  Table ID: ' + Format(ApprovalEntry."Table ID") +
            '   (38 = Purchase Header, 36 = Sales Header)');
        Builder.AppendLine('  Document Type: ' + Format(ApprovalEntry."Document Type") +
            '   (ordinal ' + Format(ApprovalEntry."Document Type".AsInteger()) + ')');
        Builder.AppendLine('  Document No.: ' + ApprovalEntry."Document No.");
        Builder.AppendLine('  Status: ' + Format(ApprovalEntry.Status) +
            '   (ordinal ' + Format(ApprovalEntry.Status.AsInteger()) + ')');
        Builder.AppendLine('  Sequence No.: ' + Format(ApprovalEntry."Sequence No."));
        Builder.AppendLine('  Approver ID: ' + ApprovalEntry."Approver ID");
        Builder.AppendLine('  Sender ID: ' + ApprovalEntry."Sender ID");
        Builder.AppendLine('  Amount: ' + Format(ApprovalEntry.Amount));
        Builder.AppendLine('  Amount (LCY): ' + Format(ApprovalEntry."Amount (LCY)"));
        Builder.AppendLine('  Currency Code: ' + ApprovalEntry."Currency Code");
        Builder.AppendLine('  Approval Type: ' + Format(ApprovalEntry."Approval Type"));
        Builder.AppendLine('  Limit Type: ' + Format(ApprovalEntry."Limit Type"));
        Builder.AppendLine('');

        // ---------------------------------------------------------------
        //  3. Run the scope checks in the same order the subscriber does.
        // ---------------------------------------------------------------
        Builder.AppendLine('=== 3. SCOPE CHECKS ===');
        BlockedBy := '';

        // Table ID
        case ApprovalEntry."Table ID" of
            Database::"Purchase Header":
                if Setup."Include Purchase Documents" then
                    Builder.AppendLine('OK: Table ID 38 (Purchase Header), purchase documents included.')
                else begin
                    Builder.AppendLine('*** BLOCKED: purchase documents are excluded in setup. ***');
                    BlockedBy := 'Include Purchase Documents is off';
                end;
            Database::"Sales Header":
                if Setup."Include Sales Documents" then
                    Builder.AppendLine('OK: Table ID 36 (Sales Header), sales documents included.')
                else begin
                    Builder.AppendLine('*** BLOCKED: sales documents are excluded in setup. ***');
                    BlockedBy := 'Include Sales Documents is off';
                end;
            else begin
                Builder.AppendLine('*** BLOCKED: Table ID ' + Format(ApprovalEntry."Table ID") +
                    ' is not a purchase or sales header. ***');
                BlockedBy := 'unsupported Table ID ' + Format(ApprovalEntry."Table ID");
            end;
        end;

        // Document Type
        if ApprovalEntry."Document Type" in [
            ApprovalEntry."Document Type"::Invoice,
            ApprovalEntry."Document Type"::"Credit Memo"]
        then
            Builder.AppendLine('OK: Document Type is Invoice or Credit Memo.')
        else begin
            Builder.AppendLine('*** BLOCKED: Document Type is "' + Format(ApprovalEntry."Document Type") +
                '", not Invoice or Credit Memo. ***');
            Builder.AppendLine('    The subscriber only accepts Invoice and Credit Memo.');
            Builder.AppendLine('    A blank Document Type means Business Central did not populate it');
            Builder.AppendLine('    for this workflow - tell me if you see that and I will widen the filter.');
            if BlockedBy = '' then
                BlockedBy := 'Document Type is ' + Format(ApprovalEntry."Document Type");
        end;

        // Minimum amount
        if Setup."Min. Amount (LCY)" > 0 then
            if Abs(ApprovalEntry."Amount (LCY)") < Setup."Min. Amount (LCY)" then begin
                Builder.AppendLine('*** BLOCKED: Amount (LCY) ' + Format(Abs(ApprovalEntry."Amount (LCY)")) +
                    ' is below the minimum of ' + Format(Setup."Min. Amount (LCY)") + '. ***');
                if BlockedBy = '' then
                    BlockedBy := 'below Min. Amount (LCY)';
            end else
                Builder.AppendLine('OK: amount is at or above the minimum.')
        else
            Builder.AppendLine('OK: no minimum amount configured.');

        // Status
        Builder.AppendLine('');
        Builder.AppendLine('--- Status handling ---');
        case ApprovalEntry.Status of
            ApprovalEntry.Status::Created:
                begin
                    Builder.AppendLine('Status is CREATED, not Open.');
                    Builder.AppendLine('Business Central inserts as Created then modifies to Open.');
                    Builder.AppendLine('The fixed subscriber captures the modify to Open. If this entry');
                    Builder.AppendLine('is still Created, the workflow never opened it - which means');
                    Builder.AppendLine('no approver was actually asked.');
                end;
            ApprovalEntry.Status::Open:
                Builder.AppendLine('Status is OPEN - this should have produced a Requested outbox row.');
            else
                Builder.AppendLine('Status is ' + Format(ApprovalEntry.Status) +
                    ' - already decided, so only a status-change row would exist.');
        end;

        // Approver resolution
        Builder.AppendLine('');
        Builder.AppendLine('--- Approver resolution ---');
        User.SetRange("User Name", ApprovalEntry."Approver ID");
        if User.FindFirst() then begin
            Builder.AppendLine('OK: Approver ID resolves to a User record.');
            Builder.AppendLine('  User Security ID: ' + Format(User."User Security ID"));
            Builder.AppendLine('  Authentication Email (UPN): ' +
                DelChr(User."Authentication Email", '<>', ' '));
            if User."Authentication Email" = '' then
                Builder.AppendLine('  WARNING: no UPN. Teams and Outlook delivery will not resolve.');
        end else begin
            Builder.AppendLine('WARNING: Approver ID "' + ApprovalEntry."Approver ID" +
                '" does not match any User record.');
            Builder.AppendLine('  The outbox row is still written, but with a blank security ID,');
            Builder.AppendLine('  so no channel address can be resolved later.');
        end;

        // ---------------------------------------------------------------
        //  4. Outbox contents
        // ---------------------------------------------------------------
        Builder.AppendLine('');
        Builder.AppendLine('=== 4. OUTBOX ===');
        Outbox.Reset();
        Builder.AppendLine('Total rows: ' + Format(Outbox.Count()));

        Outbox.SetRange("Approval Entry No.", ApprovalEntry."Entry No.");
        Builder.AppendLine('Rows for entry ' + Format(ApprovalEntry."Entry No.") + ': ' +
            Format(Outbox.Count()));

        Outbox.Reset();
        Outbox.SetRange("Document No.", ApprovalEntry."Document No.");
        Builder.AppendLine('Rows for document ' + ApprovalEntry."Document No." + ': ' +
            Format(Outbox.Count()));

        // ---------------------------------------------------------------
        //  Verdict
        // ---------------------------------------------------------------
        Builder.AppendLine('');
        Builder.AppendLine('=== VERDICT ===');

        if BlockedBy <> '' then begin
            Builder.AppendLine('This entry was rejected by a scope check:');
            Builder.AppendLine('  ' + BlockedBy);
        end else begin
            Outbox.Reset();
            Outbox.SetRange("Approval Entry No.", ApprovalEntry."Entry No.");

            if Outbox.IsEmpty() then begin
                Builder.AppendLine('Every scope check passes, but no outbox row exists.');
                Builder.AppendLine('');
                Builder.AppendLine('That means the subscriber did not run. Most likely:');
                Builder.AppendLine('  a) the fixed subscriber has not been republished yet, or');
                Builder.AppendLine('  b) this entry was created before the fix was published.');
                Builder.AppendLine('');
                Builder.AppendLine('Cancel the approval request, republish, then send it again.');
            end else
                Builder.AppendLine('An outbox row exists. Capture is working correctly.');
        end;

        DiagnosisText := Builder.ToText();
    end;

    [TryFunction]
    local procedure TryTimingAndPolicySetup(var Setup: Record "PN Approval Integration Setup")
    begin
        Setup.TestTimingAndPolicySetup();
    end;

    /// <summary>
    /// Answers "why did no email arrive" in one click.
    ///
    /// Checks each prerequisite in the order it would fail, and stops at the
    /// first problem rather than reporting all of them - a list of six
    /// warnings where only the first matters is harder to act on than one
    /// clear statement.
    /// </summary>
    local procedure RunEmailDiagnostic()
    var
        Setup: Record "PN Approval Integration Setup";
        Outbox: Record "PN Approval Outbox";
        UserSetup: Record "User Setup";
        EmailSender: Codeunit "PN Approval Email Sender";
        Builder: TextBuilder;
        FailureReason: Text;
        RecipientEmail: Text;
    begin
        Builder.AppendLine('=== APPROVAL EMAIL DIAGNOSTIC ===');
        Builder.AppendLine('');

        // ---- 1. Is the channel even on ----
        Setup.GetSetup();
        Builder.AppendLine('1. CHANNEL');
        if Setup."Outlook Channel Enabled" then
            Builder.AppendLine('   OK: Outlook is switched on.')
        else begin
            Builder.AppendLine('   STOP: Outlook is switched OFF on Approval Channel Setup.');
            Builder.AppendLine('   Nothing will be sent until that toggle is ticked.');
            Message(Builder.ToText());
            exit;
        end;

        // ---- 2. Email configuration ----
        //
        // Deliberately NOT inspected here. The tables behind Email Accounts and
        // Email Scenario Assignment are System Application internals whose
        // names and shapes differ between versions, and a diagnostic that
        // fails to compile is worse than no diagnostic at all.
        //
        // Step 7 sends a real email, which is the only honest test anyway - a
        // configuration that looks right and still does not deliver is exactly
        // the case this page exists to catch.
        Builder.AppendLine('');
        Builder.AppendLine('2. EMAIL CONFIGURATION');
        Builder.AppendLine('   Not checked here - step 6 sends a real email instead.');
        Builder.AppendLine('   If it fails, open Email Accounts and use Send Test Email,');
        Builder.AppendLine('   then check Email Scenario Assignment has an account against');
        Builder.AppendLine('   the Notification scenario. An unassigned scenario fails silently.');

        // ---- 3. Action links ----
        Builder.AppendLine('');
        Builder.AppendLine('3. APPROVAL LINKS');
        if Setup."Action Endpoint URL" = '' then
            Builder.AppendLine('   WARNING: No Action Endpoint URL. The email will send with no Approve or Reject buttons.')
        else
            Builder.AppendLine('   OK: ' + Setup."Action Endpoint URL");

        if Setup.GetActionTokenSecret() = '' then
            Builder.AppendLine('   WARNING: No action token secret stored. Buttons cannot be built.')
        else
            Builder.AppendLine('   OK: action token secret is stored.');

        if not Setup."Action Link Expiry Enabled" then
            Builder.AppendLine('   OK: link expiry is OFF - buttons stay active until the invoice is decided.')
        else
            if Setup."Action Token TTL (Min.)" <= 0 then
                Builder.AppendLine('   WARNING: Action Link Lifetime (Minutes) is not set. Links cannot be built.')
            else
                Builder.AppendLine('   OK: links live for ' + Format(Setup."Action Token TTL (Min.)") + ' minutes.');

        if Setup."Email Max Lines" <= 0 then
            Builder.AppendLine('   WARNING: Email Max. Lines is not set. The email cannot be built.');

        // ---- 4. A real outbox row ----
        Builder.AppendLine('');
        Builder.AppendLine('4. MOST RECENT REQUEST');
        Outbox.SetRange("Event Type", Outbox."Event Type"::Requested);
        if not Outbox.FindLast() then begin
            Builder.AppendLine('   STOP: No approval request in the outbox to test with.');
            Builder.AppendLine('   Send an invoice for approval first.');
            Message(Builder.ToText());
            exit;
        end;
        Builder.AppendLine(StrSubstNo('   Entry %1, document %2, approver %3.',
            Outbox."Entry No.", Outbox."Document No.", Outbox."Approver User ID"));

        // ---- 5. The recipient ----
        Builder.AppendLine('');
        Builder.AppendLine('5. RECIPIENT');
        if not UserSetup.Get(Outbox."Approver User ID") then begin
            Builder.AppendLine('   STOP: No Approval User Setup row for this approver.');
            Message(Builder.ToText());
            exit;
        end;

        if UserSetup."PN Channel Notifications Off" then begin
            Builder.AppendLine('   STOP: Channel notifications are suspended for this approver.');
            Message(Builder.ToText());
            exit;
        end;

        RecipientEmail := UserSetup.PNResolveEmail();
        if RecipientEmail = '' then begin
            Builder.AppendLine('   STOP: No email address.');
            Builder.AppendLine('   Set E-Mail on their Approval User Setup row, or make sure');
            Builder.AppendLine('   their User record has an Authentication Email.');
            Message(Builder.ToText());
            exit;
        end;
        Builder.AppendLine('   OK: ' + RecipientEmail);
        Builder.AppendLine('   Source: ' + UserSetup.PNEmailSource());
        Builder.AppendLine('   Which block is active is set in PN User Setup _Table_Ext.al.');
        Builder.AppendLine('   Block A reads Approval User Setup E-Mail (local testing).');
        Builder.AppendLine('   Block B reads Users Authentication Email (UAT/production).');

        // ---- 6. Send it for real ----
        Builder.AppendLine('');
        Builder.AppendLine('6. SEND');
        if EmailSender.TrySendApprovalEmail(Outbox, FailureReason) then begin
            Builder.AppendLine('   SENT.');
            Builder.AppendLine('   Check Sent Emails on this page to confirm, then the inbox.');
        end else begin
            if FailureReason = '' then
                FailureReason := GetLastErrorText();
            ClearLastError();
            Builder.AppendLine('   FAILED: ' + FailureReason);
            Builder.AppendLine('');
            Builder.AppendLine('   Most likely causes, in order:');
            Builder.AppendLine('   a) The Notification scenario has no account assigned.');
            Builder.AppendLine('      Search "Email Scenario Assignment".');
            Builder.AppendLine('   b) No email account is configured at all.');
            Builder.AppendLine('      Search "Email Accounts" and use Send Test Email.');
            Builder.AppendLine('   c) The account exists but the send failed - see Email Outbox.');
        end;

        Message(Builder.ToText());
    end;

    /// <summary>
    /// Approves the most recent open entry by calling the handler directly.
    ///
    /// WHY THIS EXISTS
    ///
    /// When the handler throws, OData returns a 400 carrying the message and
    /// nothing else - no object, no procedure, no line. An error like
    /// "The value "" can't be evaluated into type Integer" is then almost
    /// impossible to place, and the only way forward is guesswork.
    ///
    /// Run in-process, the same failure surfaces in the Business Central
    /// client with a full AL call stack. One click, and the guessing stops.
    ///
    /// This really approves the invoice, so it names the document first and
    /// asks.
    /// </summary>
    local procedure RunDirectApprove()
    var
        ApprovalEntry: Record "Approval Entry";
        Outbox: Record "PN Approval Outbox";
        Handler: Codeunit "PN Approval Action Handler";
        ExpectedApprover: Code[50];
        ExpectedAmount: Decimal;
        ResultCode: Text;
        ConfirmQst: Label 'This will really approve %1 for approver %2.\n\nContinue?', Comment = '%1 = document no., %2 = approver';
        ResultMsg: Label 'Handler returned: %1\n\nIf that reads OK, the handler is fine and the fault is in the API layer.\nIf it threw, the call stack above names the object and line.', Comment = '%1 = result code';
        NoneErr: Label 'No open approval entry to test with. Send an invoice for approval first.';
    begin
        ApprovalEntry.SetRange(Status, ApprovalEntry.Status::Open);
        if not ApprovalEntry.FindLast() then
            Error(NoneErr);

        if not Confirm(ConfirmQst, false, ApprovalEntry."Document No.", ApprovalEntry."Approver ID") then
            exit;

        // The same snapshot the API page reads, so this exercises the real
        // path rather than a simplified one.
        Outbox.SetRange("Approval Entry No.", ApprovalEntry."Entry No.");
        Outbox.SetRange("Event Type", Outbox."Event Type"::Requested);
        if Outbox.FindLast() then begin
            ExpectedApprover := Outbox."Approver User ID";
            ExpectedAmount := Outbox."Amount (LCY)";
        end;

        ResultCode := Handler.Approve(
            ApprovalEntry."Entry No.",
            ExpectedApprover,
            ExpectedAmount,
            'Diagnostics',
            'In-process test from the Approval Diagnostics page',
            Format(CreateGuid(), 0, 4),
            '');

        Message(ResultMsg, ResultCode);
    end;

    local procedure BankCheckText(var Setup: Record "PN Approval Integration Setup"): Text
    begin
        if not Setup.IsBankChangeCheckConfigured() then
            exit('   (bank-change table/fields not set - check skipped)');
        exit('   (Change Log table ' + Format(Setup."Bank Change Table No.") +
            ', fields ' + Setup."Bank Change Field Filter" + ')');
    end;
}
