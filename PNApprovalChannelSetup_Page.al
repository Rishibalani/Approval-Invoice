// =========================================================================
//  PN Approval Channel Setup
// =========================================================================
//
//  The one page that decides where approval notifications go.
//
//  Deliberately tiny. It shares the setup table with Approval Integration
//  Setup, but shows none of the endpoints, keys, thresholds or retry policy -
//  the person who flips WhatsApp off for an afternoon should not have to
//  scroll past a signing secret to do it.
//
//  These toggles are GLOBAL. Turning Teams off stops Teams for every
//  approver, immediately, with no redeploy and nothing to change in Azure.
//  The Azure Function reads the resulting list from each payload and sends to
//  exactly those channels; it has no opinion of its own about which are in
//  use. Azure configuration only says HOW a channel is reached, never whether.
// =========================================================================
page 50107 "PN Approval Channel Setup"
{
    Caption = 'Approval Channel Setup';
    PageType = Card;
    ApplicationArea = All;
    UsageCategory = Administration;
    SourceTable = "PN Approval Integration Setup";
    InsertAllowed = false;
    DeleteAllowed = false;
    AboutTitle = 'Approval Channel Setup';
    AboutText = 'Choose which channels approval notifications are sent on. These switches apply to every approver and take effect on the next dispatch.';

    layout
    {
        area(Content)
        {
            group(Channels)
            {
                Caption = 'Channels';
                InstructionalText = 'These apply to everyone. An approver who is suspended receives nothing regardless of what is switched on here.';

                field("Teams Channel Enabled"; Rec."Teams Channel Enabled")
                {
                    ApplicationArea = All;
                    Caption = 'Microsoft Teams';

                    trigger OnValidate()
                    begin
                        SaveAndRefresh();
                    end;
                }
                field("Outlook Channel Enabled"; Rec."Outlook Channel Enabled")
                {
                    ApplicationArea = All;
                    Caption = 'Outlook';

                    trigger OnValidate()
                    begin
                        SaveAndRefresh();
                    end;
                }
                field("WhatsApp Channel Enabled"; Rec."WhatsApp Channel Enabled")
                {
                    ApplicationArea = All;
                    Caption = 'WhatsApp';

                    trigger OnValidate()
                    begin
                        SaveAndRefresh();

                        if Rec."WhatsApp Channel Enabled" then
                            Message(WhatsAppReminderMsg);
                    end;
                }
            }

            group(Fallback)
            {
                Caption = 'Fallback';
                InstructionalText = 'Used only when every enabled channel has failed for an approver.';

                field("Global Fallback Channel"; Rec."Global Fallback Channel")
                {
                    ApplicationArea = All;
                    Caption = 'Fallback Channel';

                    trigger OnValidate()
                    begin
                        Rec.Modify(true);
                    end;
                }
            }

            group(Status)
            {
                Caption = 'Current State';
                

                field(EnabledSummary; EnabledSummary)
                {
                    ApplicationArea = All;
                    Editable = false;
                    Caption = 'Sending On';
                    StyleExpr = SummaryStyle;
                    ToolTip = 'Exactly what will be written into the next payload. If this reads None, notifications stop - approvals still work normally inside Business Central.';
                }
                field(Enabled; Rec.Enabled)
                {
                    ApplicationArea = All;
                    Caption = 'Integration Enabled';
                    ToolTip = 'The master switch, on Approval Integration Setup. When off, events are still captured to the outbox but nothing is dispatched, so nothing is lost while paused.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(OpenFullSetup)
            {
                ApplicationArea = All;
                Caption = 'Integration Setup';
                Image = Setup;
                RunObject = page "PN Approval Integration Setup";
                ToolTip = 'Opens the full setup page - endpoints, credentials, thresholds and retry policy.';
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
                actionref(OpenOutbox_P; OpenOutbox) { }
                actionref(OpenFullSetup_P; OpenFullSetup) { }
            }
        }
    }

    var
        EnabledSummary: Text;
        SummaryStyle: Text;
        NoneTxt: Label 'None - no notifications will be sent. Approvals still work normally inside Business Central.';
        WhatsAppReminderMsg: Label 'WhatsApp also needs an approved Meta template and a recorded consent date against each approver. Without both, WhatsApp delivery is skipped for that person and the reason is logged.';

    trigger OnOpenPage()
    begin
        Rec.GetSetup();
    end;

    trigger OnAfterGetCurrRecord()
    begin
        RefreshSummary();
    end;

    local procedure RefreshSummary()
    var
        Channels: List of [Text];
        ChannelName: Text;
    begin
        Channels := Rec.GetEnabledChannels();

        if Channels.Count() = 0 then begin
            EnabledSummary := NoneTxt;
            SummaryStyle := 'Unfavorable';
            exit;
        end;

        EnabledSummary := '';
        foreach ChannelName in Channels do begin
            if EnabledSummary <> '' then
                EnabledSummary += ', ';
            EnabledSummary += ChannelName;
        end;

        SummaryStyle := 'Favorable';
    end;

    /// <summary>
    /// Persists the toggle, then recomputes the summary line.
    ///
    /// Modify(true) rather than CurrPage.Update: passing false to
    /// CurrPage.Update means "do not save", so the framework re-reads the
    /// record from the database and silently discards the toggle the user just
    /// flipped - it snaps straight back off with no error. Passing true asks
    /// the framework to save mid-validation, which can raise "the record has
    /// been modified by another user" on a Card page. Writing the record here
    /// and leaving the repaint to the framework avoids both.
    ///
    /// No Message here either. A modal inside OnValidate interrupts the
    /// validation cycle; the red "None" on the summary line says the same
    /// thing without stopping anyone.
    /// </summary>
    local procedure SaveAndRefresh()
    begin
        Rec.Modify(true);
        RefreshSummary();
    end;
}
