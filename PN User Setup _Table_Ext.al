// =========================================================================
//  PN User Setup Ext
// =========================================================================
//
//  Per-approver channel settings, held on the standard Approval User Setup
//  table rather than in a custom one.
//
//  WHY THESE LIVE HERE NOW
//
//  There used to be a separate table, PN Approver Channel Identity, keyed on
//  User Security ID. The argument was that a security ID is immutable while a
//  User ID can be renamed.
//
//  In practice that argument did not survive contact with the system. Nobody
//  renames a Business Central User ID, and if they did, Approval User Setup
//  would break in exactly the same way - so the integration was no better off.
//  Meanwhile the separate table carried twelve fields of which four did real
//  work: three were caches of the User table, four were obsoleted when channel
//  control moved to global toggles, and one duplicated a field already here.
//
//  Four fields do not justify a table, two pages and an API page.
//
//  Approval User Setup already has a row for every approver. It already holds
//  their approval limit, their approver, and their substitute. It is where an
//  administrator looks for approver configuration, and it is where the native
//  approval framework reads from. Putting channel preferences alongside means
//  one page, one row, one place to look.
// =========================================================================
tableextension 50100 "PN User Setup Ext" extends "User Setup"
{
    fields
    {
        field(50100; "PN Entra Object ID"; Guid)
        {
            Caption = 'Entra Object ID';
            DataClassification = OrganizationIdentifiableInformation;
            ToolTip = 'The Microsoft Entra object ID of this user. Lets Teams approval cards reach them without a Microsoft Graph lookup on every dispatch. The Azure Function fills this in on first use; leave it blank and it populates itself.';
        }

        field(50101; "PN Mobile Number"; Text[30])
        {
            Caption = 'Mobile Number (E.164)';
            DataClassification = CustomerContent;
            ExtendedDatatype = PhoneNo;
            ToolTip = 'The mobile number WhatsApp approval messages are sent to. Must be in E.164 format - a leading plus sign, then the country code, no spaces or dashes. For example +919722821516.';

            trigger OnValidate()
            begin
                if "PN Mobile Number" = '' then
                    exit;

                // Meta rejects anything that is not E.164, and the error it
                // returns does not say so. Catching it here means the person
                // typing the number finds out immediately rather than a week
                // later when an approval silently fails to arrive.
                if CopyStr("PN Mobile Number", 1, 1) <> '+' then
                    Error(E164Err);
            end;
        }

        field(50102; "PN WhatsApp Consent"; Boolean)
        {
            Caption = 'WhatsApp Consent Given';
            DataClassification = CustomerContent;
            ToolTip = 'Records that this approver was told their name, the counterparty and the invoice amount will be sent to WhatsApp. Messages are not sent without it.';

            trigger OnValidate()
            begin
                // The date is set automatically rather than typed, because a
                // consent record whose date can be edited is not much of a
                // record.
                if "PN WhatsApp Consent" then begin
                    if "PN WhatsApp Consent Date" = 0DT then
                        "PN WhatsApp Consent Date" := CurrentDateTime();
                end else
                    "PN WhatsApp Consent Date" := 0DT;
            end;
        }

        field(50103; "PN WhatsApp Consent Date"; DateTime)
        {
            Caption = 'WhatsApp Consent Date';
            DataClassification = CustomerContent;
            Editable = false;
            ToolTip = 'When consent was recorded. Set automatically when the consent flag is ticked.';
        }

        field(50104; "PN Personal High Value Thr."; Decimal)
        {
            Caption = 'Personal High Value Threshold (LCY)';
            DataClassification = CustomerContent;
            MinValue = 0;
            AutoFormatType = 1;
            ToolTip = 'A stricter approval ceiling for this person than the global one. Above this amount they must approve inside Business Central rather than from a message. Leave at zero to use the global threshold.';
        }

        field(50106; "PN BC Access"; Enum "PN BC Access Mode")
        {
            Caption = 'Business Central Access';
            DataClassification = OrganizationIdentifiableInformation;
            ToolTip = 'Whether this approver sees a View in Business Central button. Automatic decides from their licence type and assigned subscription plans. Always show and Never show override that - use them for an approver whose licence this check cannot see, or one who should never be sent into the client.';
        }
        field(50105; "PN Channel Notifications Off"; Boolean)
        {
            Caption = 'Suspend Channel Notifications';
            DataClassification = CustomerContent;
            ToolTip = 'Stops all Teams, Outlook and WhatsApp notifications for this person without changing anything else. Use while someone is on leave - their approvals still work normally inside Business Central.';
        }
    }

    var
        E164Err: Label 'The mobile number must be in E.164 format and start with a plus sign, for example +919722821516.';

    // ==================================================================
    //  EMAIL RESOLUTION - ONE BLOCK ACTIVE AT A TIME
    // ==================================================================
    //
    //  Two versions live below. Exactly ONE must be uncommented.
    //
    //  ------------------------------------------------------------------
    //   CURRENTLY ACTIVE:  BLOCK A  (LOCAL TESTING)
    //  ------------------------------------------------------------------
    //
    //  WHEN DEPLOYING TO UAT OR PRODUCTION:
    //    1. Comment out BLOCK A  - both PNResolveEmail and PNEmailSource
    //    2. Uncomment BLOCK B    - both PNResolveEmail and PNEmailSource
    //    3. Search this file for "BLOCK A" to confirm nothing is left active
    //
    //  WHY THEY DIFFER
    //
    //  Block A reads E-Mail from this Approval User Setup row. That field is
    //  editable, so a tester can point approval mail at their own address
    //  without touching anyone's sign-in details.
    //
    //  Block B reads Authentication Email from the User record. That is the
    //  Entra UPN - the address the person actually signs in with, maintained
    //  by whoever manages Microsoft 365, and impossible to get wrong by
    //  editing the wrong row. It is read-only on SaaS, which is precisely why
    //  it is unsuitable for local testing and right for production.
    //
    //  THE RISK IN BLOCK A, STATED PLAINLY
    //
    //  An approver with a blank E-Mail on their Approval User Setup row
    //  receives NOTHING. No error, no bounce - the dispatcher records
    //  "no email address" on the outbox row and moves on. Fine when you are
    //  testing one person; silently drops everybody else.
    //
    //  A THIRD OPTION, IF YOU WANT IT LATER
    //
    //  Prefer E-Mail when set, fall back to Authentication Email. That gives
    //  production the override - useful when a finance team wants approvals
    //  reaching a shared inbox several people watch - while still working for
    //  an approver nobody has configured. Business Central's own approval
    //  notifications read E-Mail, so it follows an established convention.
    //  Not active here because the instruction was a clean either/or.
    // ==================================================================

    // ┌────────────────────────────────────────────────────────────────┐
    // │  BLOCK A - LOCAL TESTING - ACTIVE                              │
    // │  Reads: Approval User Setup -> E-Mail                          │
    // └────────────────────────────────────────────────────────────────┘

    /// <summary>
    /// LOCAL TESTING. Reads only the E-Mail field on this Approval User Setup
    /// row, so a tester can redirect approval mail by editing one editable
    /// field. An approver with a blank E-Mail receives nothing.
    ///
    /// Swap to Block B before UAT or production.
    /// </summary>
    procedure PNResolveEmail() Email: Text[250]
    begin
        if "User ID" = '' then
            exit('');

        exit(CopyStr("E-Mail", 1, 250));
    end;

    /// <summary>Which source supplied the address, for the diagnostic page.</summary>
    procedure PNEmailSource(): Text
    begin
        if "User ID" = '' then
            exit('no user id');

        if "E-Mail" <> '' then
            exit('Approval User Setup, E-Mail (BLOCK A - local testing)');

        exit('NOWHERE - E-Mail is blank on this row. Block A reads only this field; ' +
             'the User-table version is Block B in PN User Setup _Table_Ext.al');
    end;

    // ┌────────────────────────────────────────────────────────────────┐
    // │  BLOCK B - UAT AND PRODUCTION - COMMENTED OUT                  │
    // │  Reads: User -> Authentication Email                           │
    // │  Uncomment this and comment Block A above before deploying.    │
    // └────────────────────────────────────────────────────────────────┘

    // /// <summary>
    // /// UAT AND PRODUCTION. Reads Authentication Email from the User record -
    // /// the Entra UPN the person signs in with, maintained by whoever manages
    // /// Microsoft 365.
    // ///
    // /// Read-only on SaaS, which is why it cannot be used for local testing
    // /// and why it is the right source for production: there is no second
    // /// field to fall out of step, and a new approver works on day one with
    // /// nobody having to configure anything.
    // /// </summary>
    // procedure PNResolveEmail() Email: Text[250]
    // var
    //     User: Record User;
    // begin
    //     if "User ID" = '' then
    //         exit('');
    //
    //     User.SetRange("User Name", "User ID");
    //     if User.FindFirst() then
    //         exit(User."Authentication Email");
    //
    //     exit('');
    // end;
    //
    // /// <summary>Which source supplied the address, for the diagnostic page.</summary>
    // procedure PNEmailSource(): Text
    // var
    //     User: Record User;
    // begin
    //     if "User ID" = '' then
    //         exit('no user id');
    //
    //     User.SetRange("User Name", "User ID");
    //     if User.FindFirst() then
    //         if User."Authentication Email" <> '' then
    //             exit('Users, Authentication Email (BLOCK B - UAT/production)');
    //
    //     exit('NOWHERE - no Authentication Email on this user''s User record');
    // end;

    // ==================================================================
    //  END OF EMAIL RESOLUTION
    // ==================================================================

    /// <summary>Display name for this approver, falling back to the user ID.</summary>
    procedure PNResolveFullName(): Text
    var
        User: Record User;
    begin
        if "User ID" = '' then
            exit('');

        User.SetRange("User Name", "User ID");
        if User.FindFirst() then
            if User."Full Name" <> '' then
                exit(User."Full Name");

        exit("User ID");
    end;

    /// <summary>
    /// Whether this approver can actually open Business Central, which decides
    /// whether a channel shows them a "View in Business Central" button.
    ///
    /// WHY LICENCE TYPE ALONE IS NOT ENOUGH
    ///
    /// The User card's License Type says Full User for a user with no licence
    /// assigned at all - it is what the account was created as, not what is
    /// paid for today. The Licenses list on that same page can be empty beside
    /// it. Checking only the type therefore sends people to an access-denied
    /// page, so this also asks whether any subscription plan is assigned.
    ///
    /// Three inputs, in order:
    ///   1. PN BC Access on this row. Always show or Never show ends it.
    ///   2. Licence type, matched against BC License Types on the setup page.
    ///   3. At least one subscription plan, when Require Subscription Plan is on.
    /// </summary>
    procedure PNIsBcLicensedUser(): Boolean
    var
        Reason: Text;
    begin
        exit(PNEvaluateBcAccess(Reason));
    end;

    /// <summary>
    /// The same decision, with a sentence saying how it was reached. Used by
    /// Approval Diagnostics, because "the button is missing" is otherwise a
    /// question nobody can answer without a debugger.
    /// </summary>
    procedure PNEvaluateBcAccess(var Reason: Text) CanOpen: Boolean
    var
        Setup: Record "PN Approval Integration Setup";
        User: Record User;
        LicenseName: Text;
        PlanCount: Integer;
    begin
        case "PN BC Access" of
            "PN BC Access"::Always:
                begin
                    Reason := 'Business Central Access is set to Always show on this approver.';
                    exit(true);
                end;
            "PN BC Access"::Never:
                begin
                    Reason := 'Business Central Access is set to Never show on this approver.';
                    exit(false);
                end;
        end;

        if "User ID" = '' then begin
            Reason := 'No user ID on this Approval User Setup row.';
            exit(false);
        end;

        User.SetRange("User Name", "User ID");
        if not User.FindFirst() then begin
            Reason := StrSubstNo('No User record named %1, so no way to sign in.', "User ID");
            exit(false);
        end;

        LicenseName := PNLicenseTypeName(User);
        Setup.GetSetup();

        if not Setup.IsBcLicenseTypeAllowed(LicenseName) then begin
            Reason := StrSubstNo('Licence type %1 is not in BC License Types on the setup page.', LicenseName);
            exit(false);
        end;

        PlanCount := PNCountSubscriptionPlans(User."User Security ID");

        if Setup."Require Subscription Plan" and (PlanCount = 0) then begin
            Reason := StrSubstNo(
                'Licence type %1, but no subscription plan is assigned - the Licenses list on the User card is empty.',
                LicenseName);
            exit(false);
        end;

        Reason := StrSubstNo('Licence type %1, %2 subscription plan(s) assigned.', LicenseName, PlanCount);
        exit(true);
    end;

    /// <summary>
    /// The licence type as a stable English name.
    ///
    /// Format() would return the translated caption, which stops matching the
    /// setup list the moment somebody opens Business Central in another
    /// language. An explicit map is boring and does not move.
    /// </summary>
    procedure PNLicenseTypeName(var User: Record User): Text
    begin
        case User."License Type" of
            User."License Type"::"Full User":
                exit('Full User');
            User."License Type"::"Limited User":
                exit('Limited User');
            User."License Type"::"External Administrator":
                exit('External Administrator');
            User."License Type"::"External Accountant":
                exit('External Accountant');
            User."License Type"::"External User":
                exit('External User');
            User."License Type"::"Device Only User":
                exit('Device Only User');
            User."License Type"::"Windows Group":
                exit('Windows Group');
            User."License Type"::"AAD Group":
                exit('AAD Group');
            User."License Type"::Application:
                exit('Application');
        end;

        // Anything newer than this build knows about - Agent, say - falls
        // through to the platform's own name, which is what the setup list is
        // written against anyway.

        exit(Format(User."License Type"));
    end;

    /// <summary>
    /// How many subscription plans are assigned to this user - the same list
    /// the Licenses part on the User card shows.
    ///
    /// Read through the platform query rather than the User Plan table, which
    /// is internal and cannot be read from an extension.
    /// </summary>
    procedure PNCountSubscriptionPlans(UserSecurityId: Guid) PlanCount: Integer
    var
        UsersInPlans: Query "Users in Plans";
    begin
        if IsNullGuid(UserSecurityId) then
            exit(0);

        UsersInPlans.SetRange(User_Security_ID, UserSecurityId);
        UsersInPlans.Open();

        while UsersInPlans.Read() do
            PlanCount += 1;

        UsersInPlans.Close();
    end;

    procedure PNResolveUserSecurityId(): Guid
    var
        User: Record User;
        Empty: Guid;
    begin
        if "User ID" = '' then
            exit(Empty);

        User.SetRange("User Name", "User ID");
        if User.FindFirst() then
            exit(User."User Security ID");

        exit(Empty);
    end;

    /// <summary>
    /// The effective high value ceiling: the stricter of the global setting and
    /// any personal override.
    ///
    /// A personal value of zero means "no override", not "no threshold" - so a
    /// personal setting can only ever tighten the control, never loosen it.
    /// </summary>
    procedure PNEffectiveHighValueThreshold(GlobalThreshold: Decimal): Decimal
    begin
        if "PN Personal High Value Thr." = 0 then
            exit(GlobalThreshold);
        if GlobalThreshold = 0 then
            exit("PN Personal High Value Thr.");
        if "PN Personal High Value Thr." < GlobalThreshold then
            exit("PN Personal High Value Thr.");
        exit(GlobalThreshold);
    end;

    /// <summary>
    /// Finds the Approval User Setup row for an approver, creating one if it
    /// does not exist.
    ///
    /// Auto-creation means the integration works for a new approver on day
    /// one. The row can be tuned afterwards, and a blank row behaves exactly
    /// as the global defaults would.
    /// </summary>
    procedure PNGetOrCreate(ApproverUserId: Code[50]): Boolean
    begin
        if ApproverUserId = '' then
            exit(false);

        if Get(ApproverUserId) then
            exit(true);

        Init();
        "User ID" := ApproverUserId;
        exit(Insert(true));
    end;
}
