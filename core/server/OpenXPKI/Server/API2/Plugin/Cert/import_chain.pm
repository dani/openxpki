package OpenXPKI::Server::API2::Plugin::Cert::import_chain;
use OpenXPKI::Server::API2::EasyPlugin;

=head1 NAME

OpenXPKI::Server::API2::Plugin::Cert::import_chain

=cut

# Project modules
use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Server::API2::Types;

# CPAN modules
use Try::Tiny;


=head1 COMMANDS

=head2 import_chain

Expects a set of certificates as PKCS7 container, concated PEM or array
of PEM blocks - expected sorting is "entity first". For security reasons
the root is not imported by default, set IMPORT_ROOT => 1 to import root
certificates. If the chain can not be build, the import will fail unless
you set FORCE_NOCHAIN => 1, which will import the chain as far as it can
be built. Certificates from the chain that are already in the database
are ignored. If the data contain certs from different chains, all chains
are built (works only with PEM array/block yet!)

Return value is a hash with keys imported and failed. Imported contains
the db_hash of the successful imports, failed contains the cert_identifier
and error message of failed imports ([{cert_identifier, error}]).

B<Parameters>

=over

=item * C<XXX> I<Bool> - XXX. Default: XXX

=item * C<pem> I<Str or ArrayRef> - PEM encoded certificate (I<Str>) or full
certificate chain (list of PEM encoded certificates) starting with the entity

=item * C<pkcs7> I<Str> - PEM encoded PKCS7 container

=back

B<Changes compared to API v1:>

The old parameter C<DATA> was split up into two separate parameters C<chain> and
C<pkcs7>.

=cut
command "import_chain" => {
    chain         => { isa => 'ArrayRefOrPEMCertChain', coerce => 1, },
    pkcs7         => { isa => 'PEMPKCS7', },
    pki_realm     => { isa => 'AlphaPunct', },
    force_nochain => { isa => 'Bool', default => 0, },
    import_root   => { isa => 'Bool', default => 0, },
} => sub {
    my ($self, $params) = @_;

    my $default_token = $self->api->get_default_token;
    my $realm = $params->has_pki_realm ? $params->pki_realm : CTX('session')->data->pki_realm;

    my @chain;
    # take given chain
    if ($params->has_chain) {
        CTX('log')->system()->debug("Importing certificate chain with ".scalar(@chain)." element(s)");
        @chain = @{ $params->chain };
    }
    # extract entity certificate from pkcs7
    elsif ($params->has_pkcs7) {
        CTX('log')->system()->debug("Importing certificate chain from PKCS7 container");
        my $chainref = $default_token->command({
            COMMAND     => 'pkcs7_get_chain',
            PKCS7       => $params->pkcs7,
        });
        @chain = @{ $chainref };
    }
    else {
        die "One of the following parameters must be specified: 'chain', 'pkcs7'";
    }

    my @imported;
    my @failed;
    my @exist;
    my $dbi = CTX("dbi");

    # We start at the end of the list
    while (my $pem = pop @chain) {
        my $cert = OpenXPKI::Crypto::X509->new(
            TOKEN => $default_token,
            DATA  => $pem,
        );
        my $cert_identifier = $cert->get_identifier();

        # Check if the certificate is already in the PKI
        my $cert_hash = $dbi->select_one(
            from => 'certificate',
            columns => [ '*' ],
            where => { identifier => $cert_identifier },
        );

        if ($cert_hash) {
            CTX('log')->system()->debug("Certificate $cert_identifier already in database, skipping");
            delete $cert_hash->{data};
            push @exist, $cert_hash;
            next;
        }

        # Check if root certificate
        my $self_signed = (defined $cert->get_subject_key_id and defined $cert->get_authority_key_id)
            ? ($cert->get_subject_key_id eq $cert->get_authority_key_id)
            : ($cert->{PARSED}->{BODY}->{SUBJECT} eq $cert->{PARSED}->{BODY}->{ISSUER});

        # Do not import root certs unless specified
        if ($self_signed and not $params->import_root) {
            CTX('log')->system()->debug("Certificate $cert_identifier is self-signed, skipping");
            next;
        }

        # Now we know that the cert does not exist and is either not a root cert
        # or root import is allowed. We now call "import_certificate" which also
        # does the chain validation
        try {
            my $db_insert = $self->api->import_certificate(
                data          => $pem,
                pki_realm     => $realm,
                force_nochain => $params->force_nochain,
            );
            push @imported, $db_insert;
            CTX('log')->system()->info("Certificate $cert_identifier sucessfully imported");
        }
        catch {
            my $err = $_;
            $err = $_->message if ref $_ eq 'OpenXPKI::Exception';
            CTX('log')->system->error("Import of certificate $cert_identifier failed with $err");
            push @failed, { cert_identifier => $cert_identifier, error => $err };
        }

    }

    return { imported => \@imported, failed => \@failed, existed => \@exist };
};

__PACKAGE__->meta->make_immutable;
