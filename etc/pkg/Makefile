# $NetBSD$
#
# pkgsrc Makefile for mlisp -- Common Lisp mailing list manager / bug
# tracker (Smartlist/Mailman 2 + Debbugs replacement).
#
# Used to build a binary package (pkg_create) for both Linux and NetBSD
# targets in CI (see .github/workflows/release.yml). PKGVERSION is
# substituted from the release tag at build time (e.g. v0.7.0 -> 0.7.0).

DISTNAME=	mlisp-@PKGVERSION@
PKGNAME=	${DISTNAME}
CATEGORIES=	mail
MASTER_SITES=	https://github.com/denzuko/mlisp/archive/refs/tags/

MAINTAINER=	denzuko@dapla.net
HOMEPAGE=	https://github.com/denzuko/mlisp
COMMENT=	Common Lisp mailing list manager and Debbugs-compatible bug tracker
LICENSE=	2-clause-bsd

# Pre-built binaries are staged by the release workflow into
# ${WRKSRC}/bin/ and ${WRKSRC}/man/ before pkg_create runs; this
# Makefile's do-install step simply relocates them under PREFIX.
NO_BUILD=	yes

INSTALLATION_DIRS=	bin man/man1 man/man7

do-install:
	${INSTALL_PROGRAM} ${WRKSRC}/bin/mlisp ${DESTDIR}${PREFIX}/bin/mlisp
	${INSTALL_PROGRAM} ${WRKSRC}/bin/mlisp-admin ${DESTDIR}${PREFIX}/bin/mlisp-admin
	${INSTALL_PROGRAM} ${WRKSRC}/bin/mlisp-bugs ${DESTDIR}${PREFIX}/bin/mlisp-bugs
	${INSTALL_PROGRAM} ${WRKSRC}/bin/mlisp-distrib ${DESTDIR}${PREFIX}/bin/mlisp-distrib
	${INSTALL_PROGRAM} ${WRKSRC}/bin/mlisp-procmail-gen ${DESTDIR}${PREFIX}/bin/mlisp-procmail-gen
	${INSTALL_MAN} ${WRKSRC}/src/man/mlisp.1 ${DESTDIR}${PREFIX}/man/man1/mlisp.1
	${INSTALL_MAN} ${WRKSRC}/src/man/mlisp-admin.1 ${DESTDIR}${PREFIX}/man/man1/mlisp-admin.1
	${INSTALL_MAN} ${WRKSRC}/src/man/mlisp-distrib.1 ${DESTDIR}${PREFIX}/man/man1/mlisp-distrib.1
	${INSTALL_MAN} ${WRKSRC}/src/man/mlisp-bugs.1 ${DESTDIR}${PREFIX}/man/man1/mlisp-bugs.1
	${INSTALL_MAN} ${WRKSRC}/src/man/mlisp-procmail-gen.1 ${DESTDIR}${PREFIX}/man/man1/mlisp-procmail-gen.1
	${INSTALL_MAN} ${WRKSRC}/src/man/mlisp-intro.7 ${DESTDIR}${PREFIX}/man/man7/mlisp-intro.7

.include "../../mk/bsd.pkg.mk"
