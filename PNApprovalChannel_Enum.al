// Delivery channels. Only Teams and Outlook are wired in phase 2; WhatsApp is
// declared now so the identity table and payload contract do not have to change
// when it is added later.
enum 50120 "PN Approval Channel"
{
    Extensible = true;
    Caption = 'PN Approval Channel';

    value(0; None) { Caption = 'None'; }
    value(1; Teams) { Caption = 'Microsoft Teams'; }
    value(2; Outlook) { Caption = 'Microsoft Outlook'; }
    value(3; WhatsApp) { Caption = 'WhatsApp'; }
}
