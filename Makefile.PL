use strict;
use warnings;
use ExtUtils::MakeMaker;

my %WriteMakefileArgs = (
    NAME               => 'Devel::ptkdb',
    AUTHOR             => ['Matthew O. Persico <persicom.cpan@gmail.com>'],
    VERSION_FROM       => 'lib/Devel/ptkdb.pm',
    ABSTRACT_FROM      => 'lib/Devel/ptkdb.pm',
    LICENSE            => 'perl',
    CONFIGURE_REQUIRES => {
        'CPAN::Meta'          => '2.150013',
        'ExtUtils::MakeMaker' => '0',
    },
    TEST_REQUIRES => {
        'Perl::Tidy'         => 0,
        'Test::More'         => 0,
        'Test::Perl::Critic' => 0,
        'version'            => 0,
    },
    PREREQ_PM => {
        'Devel::PL_origargv' => 0,
        'Ref::Util'          => 0,
        'Tk'                 => 0,
        'Tk::Adjuster'       => 0,
        'Tk::Balloon'        => 0,
        'Tk::Derived'        => 0,
        'Tk::Dialog'         => 0,
        'Tk::HList'          => 0,
        'Tk::NoteBook'       => 0,
        'Tk::ROText'         => 0,
        'Tk::Table'          => 0,
        'Tk::TextUndo'       => 0,
    },
    dist       => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean      => { FILES    => 'Module-Starter-PBP-*' },
    META_MERGE => {
        'resources' => {
            'bugtracker' => { 'web' => 'https://github.com/matthewpersico/Devel-ptkdb/issues' },
            'repository' => {
                'web'  => 'https://github.com/matthewpersico/Devel-ptkdb',
                'type' => 'git',
                'url'  => 'https://github.com/matthewpersico/Devel-ptkdb.git'
            }
        },
        'meta-spec' => { 'version' => 2 }
    },

);

# Compatibility with old versions of ExtUtils::MakeMaker
unless (eval { ExtUtils::MakeMaker->VERSION('6.64'); 1 }) {
    my $test_requires = delete $WriteMakefileArgs{TEST_REQUIRES} || {};
    @{ $WriteMakefileArgs{PREREQ_PM} }{ keys %$test_requires } = values %$test_requires;
}

unless (eval { ExtUtils::MakeMaker->VERSION('6.55_03'); 1 }) {
    my $build_requires = delete $WriteMakefileArgs{BUILD_REQUIRES} || {};
    @{ $WriteMakefileArgs{PREREQ_PM} }{ keys %$build_requires } = values %$build_requires;
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
    unless eval { ExtUtils::MakeMaker->VERSION('6.52'); 1 };
delete $WriteMakefileArgs{MIN_PERL_VERSION}
    unless eval { ExtUtils::MakeMaker->VERSION('6.48'); 1 };
delete $WriteMakefileArgs{LICENSE}
    unless eval { ExtUtils::MakeMaker->VERSION('6.31'); 1 };

WriteMakefile(%WriteMakefileArgs);
