#
# Copyright 2024 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package cloud::azure::compute::avd::mode::hosthealth;

use base qw(centreon::plugins::templates::counter);

use strict;
use warnings;

sub set_counters {
    my ($self, %options) = @_;

    $self->{maps_counters_type} = [
        { name => 'global', type => 0 }
    ];

    $self->{maps_counters}->{global} = [
        { label => 'hosts-available', nlabel => 'avd.hosts.available.count', set => {
                key_values      => [ { name => 'available' } ],
                output_template => 'Available hosts: %d',
                perfdatas       => [ { template => '%d', min => 0 } ]
            }
        },
        { label => 'hosts-unavailable', nlabel => 'avd.hosts.unavailable.count', set => {
                key_values      => [ { name => 'unavailable' } ],
                output_template => 'Unavailable hosts: %d',
                perfdatas       => [ { template => '%d', min => 0 } ]
            }
        },
        { label => 'hosts-availability', nlabel => 'avd.hosts.availability.percentage', set => {
                key_values      => [ { name => 'availability_pct' } ],
                output_template => 'Availability: %.1f%%',
                perfdatas       => [ { template => '%.1f', unit => '%', min => 0, max => 100 } ]
            }
        }
    ];
}

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options, force_new_perfdata => 1);
    bless $self, $class;

    $options{options}->add_options(arguments => {
        'workspace-id:s'    => { name => 'workspace_id' },
        'filter-hostpool:s' => { name => 'filter_hostpool' },
        'timespan:s'        => { name => 'timespan', default => 'PT5M' }
    });

    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::check_options(%options);

    if (!defined($self->{option_results}->{workspace_id}) || $self->{option_results}->{workspace_id} eq '') {
        $self->{output}->add_option_msg(short_msg => 'Need to specify --workspace-id option.');
        $self->{output}->option_exit();
    }
}

sub manage_selection {
    my ($self, %options) = @_;

    # Build KQL: for each session host, keep latest heartbeat and count statuses
    my $query = 'WVDAgentHealthStatus'
        . ' | summarize arg_max(TimeGenerated, *) by SessionHostName';

    if (defined($self->{option_results}->{filter_hostpool}) && $self->{option_results}->{filter_hostpool} ne '') {
        $query .= ' | where HostPoolName =~ "' . $self->{option_results}->{filter_hostpool} . '"';
    }

    $query .= ' | summarize Available=countif(Status == "Available"),'
            . ' Unavailable=countif(Status != "Available")';

    my $result = $options{custom}->azure_get_log_analytics(
        workspace_id => $self->{option_results}->{workspace_id},
        query        => $query,
        timespan     => $self->{option_results}->{timespan}
    );

    my ($available, $unavailable) = (0, 0);

    foreach my $table (@{$result->{tables}}) {
        # Build a column-name → index map
        my %col_idx;
        my $i = 0;
        foreach my $col (@{$table->{columns}}) {
            $col_idx{$col->{name}} = $i++;
        }

        foreach my $row (@{$table->{rows}}) {
            $available   += $row->[$col_idx{Available}]   // 0 if exists $col_idx{Available};
            $unavailable += $row->[$col_idx{Unavailable}] // 0 if exists $col_idx{Unavailable};
        }
    }

    my $total = $available + $unavailable;
    my $pct   = $total > 0 ? ($available / $total * 100) : 100;

    $self->{global} = {
        available        => $available,
        unavailable      => $unavailable,
        availability_pct => $pct
    };
}

1;

__END__

=head1 MODE

Check Azure Virtual Desktop session host health status by querying the
C<WVDAgentHealthStatus> Log Analytics table.

For each session host the latest heartbeat is kept. A host is considered
available only when its C<Status> field equals C<Available>. All other
statuses (C<NoHeartBeat>, C<NeedsAssistance>, C<Disconnected>, etc.) count
as unavailable.

Prerequisites: AVD diagnostics must be streamed to a Log Analytics workspace
(enable C<AgentHealthStatus> in the host pool diagnostic settings).

Sample command:

perl centreon_plugins.pl --plugin=cloud::azure::compute::avd::plugin \
  --custommode=api --management-endpoint='https://api.loganalytics.io' \
  --mode=host-health \
  --subscription=XXXX --tenant=XXXX --client-id=XXXX --client-secret=XXXX \
  --workspace-id=XXXX \
  --warning-hosts-unavailable=1 --critical-hosts-unavailable=3 \
  --critical-hosts-availability=90 --verbose

OK: Available hosts: 8, Unavailable hosts: 0, Availability: 100.0%
| 'avd.hosts.available.count'=8;;;0; 'avd.hosts.unavailable.count'=0;1;3;0;
  'avd.hosts.availability.percentage'=100.0%;;90;0;100

=over 8

=item B<--workspace-id>

Log Analytics workspace ID (required).

=item B<--filter-hostpool>

Filter on host pool name (exact match, case-insensitive).

=item B<--timespan>

Lookback window for the query (default: C<PT5M>).
Accepted values: C<PT5M>, C<PT15M>, C<PT30M>, C<PT1H>, C<PT6H>, C<PT12H>, C<P1D>.

=item B<--warning-hosts-available>

Warning threshold for the number of available session hosts.

=item B<--critical-hosts-available>

Critical threshold for the number of available session hosts.

=item B<--warning-hosts-unavailable>

Warning threshold for the number of unavailable session hosts.

=item B<--critical-hosts-unavailable>

Critical threshold for the number of unavailable session hosts.

=item B<--warning-hosts-availability>

Warning threshold for the host availability percentage.

=item B<--critical-hosts-availability>

Critical threshold for the host availability percentage.

=back

=cut
