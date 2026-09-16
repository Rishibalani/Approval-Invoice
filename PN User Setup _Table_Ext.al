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

        field(50105; "PN Channel Notifications Off"; Boolean)
        {
            Caption = 'Suspend Channel Notifications';
            DataClassification = CustomerContent;
            ToolTip = 'Stops all Teams, Outlook and WhatsApp notifications for this person without changing anything else. Use while someone is on leave - their approvals still work normally inside Business Central.';
        }
    }

    var
        E164Err: Label 'The mobile number must be in E.164 format and start with a plus sign, for example +919722821516.';

    /// <summary>
    /// The approver's email, read from the User table.
    ///
    /// There is deliberately no Employee fallback. Invoice approvers are
    /// finance and procurement people who frequently have no Employee record,
    /// and with no email on the User record there is nothing to match an
    /// employee ON - the only available key would be the email itself. A
    /// fallback that cannot fire is worse than none, because it reads as
    /// though the case is handled.
    ///
    /// An approver with no Authentication Email cannot be reached by email or
    /// Teams. That is a user-provisioning problem, and the dispatcher logs it
    /// as one rather than papering over it.
    /// </summary>
    procedure PNResolveEmail() Email: Text[250]
    var
        User: Record User;
    begin
        if "User ID" = '' then
            exit('');

        User.SetRange("User Name", "User ID");
        if User.FindFirst() then
            exit(User."Authentication Email");

        exit('');
    end;

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
