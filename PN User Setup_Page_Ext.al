// =========================================================================
//  PN User Setup Page Ext
// =========================================================================
//
//  Surfaces the per-approver channel settings on the page administrators
//  already use to manage approvers.
//
//  All five fields, not one. An earlier version added only the Entra object
//  ID, which left four settings that existed on the table, were read by the
//  code, and could not be set by anybody - including the personal approval
//  ceiling, which is a financial control.
// =========================================================================
pageextension 50100 "PN User Setup Page Ext" extends "User Setup"
{
    layout
    {
        addlast(Control1)
        {
            field("PN Entra Object ID"; Rec."PN Entra Object ID")
            {
                ApplicationArea = All;
                ToolTip = 'Identifies this person to Microsoft Teams. Filled in automatically the first time they interact with the approvals app, or by the bulk setup action. Leave blank - pasting it by hand is only needed if neither has run.';
            }

            field("PN Mobile Number"; Rec."PN Mobile Number")
            {
                ApplicationArea = All;
                ToolTip = 'The mobile number WhatsApp approval messages are sent to. Must start with a plus sign and the country code, with no spaces or dashes.';
            }

            field("PN WhatsApp Consent"; Rec."PN WhatsApp Consent")
            {
                ApplicationArea = All;
                ToolTip = 'Records that this person agreed to receive approval messages on WhatsApp. Nothing is sent to them without it.';
            }

            field("PN WhatsApp Consent Date"; Rec."PN WhatsApp Consent Date")
            {
                ApplicationArea = All;
                ToolTip = 'When consent was recorded. Set automatically and not editable - a consent record whose date can be changed is not much of a record.';
            }

            field("PN Personal High Value Thr."; Rec."PN Personal High Value Thr.")
            {
                ApplicationArea = All;
                ToolTip = 'A stricter approval ceiling for this person than the global one on Approval Integration Setup. At or above this amount they must approve inside Business Central rather than from a message. Leave at zero to use the global threshold. A value here can only tighten the control, never loosen it.';
            }

            field("PN Channel Notifications Off"; Rec."PN Channel Notifications Off")
            {
                ApplicationArea = All;
                ToolTip = 'Stops all Teams, Outlook and WhatsApp notifications for this person without changing anything else. Use while somebody is on leave - their approvals still work normally inside Business Central.';
            }
        } 
    }
}
