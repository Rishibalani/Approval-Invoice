// =========================================================================
//  PN Approver Identity API
// =========================================================================
//
//  Lets the Azure Function read approvers and write back the Entra object ID
//  it learned from Microsoft.
//
//  WHY THIS IS NEEDED
//
//  Teams identifies people by Entra object ID. Business Central knows them by
//  user name and email. Nothing in Business Central maps one to the other, so
//  the Function has to find out and tell it.
//
//  It finds out in one of two ways, and neither costs anything after the first
//  time:
//
//    1. The approver installs the Teams app, and Teams sends the bot their
//       object ID as part of the install notification. Free, and needs no
//       permission at all.
//
//    2. Microsoft Graph, looking the person up by email. One call, and the
//       only part of Teams delivery that needs a consented permission.
//
//  Either way the answer is written here, and neither happens again for that
//  person. Without this page the Function relearns it on every single
//  notification.
//
//  WRITES ARE DELIBERATELY NARROW
//
//  Only entraObjectId can be changed. The service account should be able to
//  record what it learned and nothing else - it has no business editing a
//  mobile number, a consent flag or an approval ceiling.
// =========================================================================
page 50108 "PN Approver Identity API"
{
    Caption = 'Approver Identity API';
    PageType = API;
    APIPublisher = 'pulsenet';
    APIGroup = 'approvals';
    APIVersion = 'v1.0';
    EntityName = 'pnApproverIdentity';
    EntitySetName = 'pnApproverIdentities';
    SourceTable = "User Setup";
    DelayedInsert = true;
    Extensible = false;
    InsertAllowed = false;
    DeleteAllowed = false;
    ODataKeyFields = SystemId;

    // Editable is deliberately NOT set to false. Business Central does not
    // expose bound actions on a non-editable API page, and it also blocks
    // PATCH - so the page would read fine and every write would fail with a
    // 404 that reads like a missing route.
    //
    // The data is kept safe by ModifyAllowed staying on but only one field
    // being editable, and by InsertAllowed and DeleteAllowed being off.

    layout
    {
        area(Content)
        {
            repeater(Group)
            {
                field(systemId; Rec.SystemId)
                {
                    Caption = 'System Id';
                    Editable = false;
                }
                field(userId; Rec."User ID")
                {
                    Caption = 'User Id';
                    Editable = false;
                }
                field(upn; Rec."E-Mail")
                {
                    Caption = 'Email';
                    Editable = false;
                }

                // The only writable field on the page.
                field(entraObjectId; Rec."PN Entra Object ID")
                {
                    Caption = 'Entra Object Id';
                }

                field(mobileNumber; Rec."PN Mobile Number")
                {
                    Caption = 'Mobile Number';
                    Editable = false;
                }
                field(whatsAppConsent; Rec."PN WhatsApp Consent")
                {
                    Caption = 'WhatsApp Consent';
                    Editable = false;
                }
                field(notificationsSuspended; Rec."PN Channel Notifications Off")
                {
                    Caption = 'Notifications Suspended';
                    Editable = false;
                }
                field(approverId; Rec."Approver ID")
                {
                    Caption = 'Approver Id';
                    Editable = false;
                }
                field(substitute; Rec.Substitute)
                {
                    Caption = 'Substitute';
                    Editable = false;
                }
            }
        }
    }

    trigger OnModifyRecord(): Boolean
    var
        Existing: Record "User Setup";
    begin
        // Guards against a write that clears a value rather than setting one.
        // The Function only ever calls this to record something it learned; a
        // blank arriving here means something went wrong upstream, and
        // overwriting a good value with nothing is worse than refusing.
        if IsNullGuid(Rec."PN Entra Object ID") then
            if Existing.Get(Rec."User ID") then
                if not IsNullGuid(Existing."PN Entra Object ID") then
                    exit(false);

        exit(true);
    end;
}
