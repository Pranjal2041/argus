package labsvc

import "errors"

// UnattendedApprovalNote makes every automatic decision visibly attributable
// in the same append-only record as a manual approval.
const UnattendedApprovalNote = "Auto-approved because Unattended Mode was on."

// AutoApprovalResult describes one store sweep. Counts include only decisions
// that were successfully committed.
type AutoApprovalResult struct {
	Keys      int
	Proposals int
}

// AutoApprovePending resolves both kinds of Lab gate currently surfaced to a
// human: access-key requests and recorded run proposals. The caller owns the
// mode switch; this method is deliberately a one-shot, auditable store action.
func (s *Store) AutoApprovePending() (AutoApprovalResult, error) {
	var result AutoApprovalResult
	var errs []error

	keys, err := s.Keys()
	if err != nil {
		errs = append(errs, err)
	} else {
		for _, key := range keys {
			if key.Status != "pending" {
				continue
			}
			if _, err := s.Decide(key.Key, true, "", UnattendedApprovalNote); err != nil {
				errs = append(errs, err)
			} else {
				result.Keys++
			}
		}
	}

	proposals, err := s.PendingProposals()
	if err != nil {
		errs = append(errs, err)
	} else {
		for _, proposal := range proposals {
			if err := s.DecideRun(proposal.Set, proposal.Run, true, UnattendedApprovalNote); err != nil {
				errs = append(errs, err)
			} else {
				result.Proposals++
			}
		}
	}

	return result, errors.Join(errs...)
}
