/// <summary>
/// Whether an approver can open Business Central, and therefore whether a
/// channel shows them a "View in Business Central" button.
///
/// Automatic covers everyone; the two overrides exist for the cases the licence
/// data cannot express - a shared mailbox approver, a contractor whose licence
/// is assigned in a way this check does not see, or an auditor who should never
/// be sent into the client.
/// </summary>
enum 50124 "PN BC Access Mode"
{
    Extensible = false;

    /// <summary>Decide from the licence type and subscription plans.</summary>
    value(0; Automatic) { Caption = 'Automatic'; }

    /// <summary>Always show the button, whatever the licence says.</summary>
    value(1; Always) { Caption = 'Always show'; }

    /// <summary>Never show the button.</summary>
    value(2; Never) { Caption = 'Never show'; }
}
