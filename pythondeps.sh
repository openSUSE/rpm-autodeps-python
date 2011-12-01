#!/bin/bash

[ $# -ge 1 ] || {
    cat > /dev/null
    exit 0
}

tmpfile=`mktemp --tmpdir pythondeps-XXXXXX`
trap "rm -f $tmpfile" EXIT
cat > $tmpfile

# Note: I could use the python pkg_config module to parse requirements, but
# that would introduce a dependency on it, which may not be desireable

pyprovides() {
    # ref: http://www.python.org/dev/peps/pep-0314/
    pkginfo="$1"
    name=`awk '/^Name:/ {print $2}' "$pkginfo"`
    echo "python${pyver}_egg($name)"
    # specified "provides"
    grep -s '^Provides:' "$pkginfo" | while read line; do
        line=`echo $line | sed 's/^Provides://;s/[[:space:]]//g'`
        pymod=`echo $line | sed 's/\([^(]\+\)\((.*\)\?/\\1/'`
        echo "python${pyver}_egg(${pymod})"
    done
}

pyrequires_distutils() {
    # ref: http://www.python.org/dev/peps/pep-0314/
    pkginfo="$1"
    grep -s '^Requires:' "$pkginfo" | while read line; do
        line=`echo $line | sed 's/^Requires://;s/[[:space:]]//g'`
        # only cover simple cases, don't try to be too smart
        echo $line | grep -qs '^[[:alnum:]]\+\(([[:alnum:]<>=.]\+)\)\?$' \
            || continue
        pymod=`echo $line | sed 's/\([^(]\+\)\((.*\)\?/\\1/'`
        echo "python${pyver}_egg(${pymod})"
    done
}

pyrequires_setuptools() {
    # ref: http://peak.telecommunity.com/DevCenter/setuptools#declaring-dependencies
    reqfile="$1"
    cat $reqfile | while read line; do
        echo $line | grep -qs '^\[' && break # stop at the first INI section
        line=`echo $line | sed 's/[[:space:]]//g'`
        [ -z "$line" ] && continue # ignore empty lines
        # only cover simple cases, don't try to be too smart
        echo $line | grep -qs '^[[:alnum:]]\+\([<>=]\+\)\?\([[:alnum:].]\+\)\?$' \
            || continue
        pymod=`echo $line | sed 's/\([[:alnum:]]\+\).*/\\1/'`
        echo "python${pyver}_egg(${pymod})"
    done
}


case $1 in
-P|--provides)
    shift
    # Match buildroot/payload paths of the form
    #    /PATH/OF/BUILDROOT/usr/bin/pythonMAJOR.MINOR
    # generating a line of the form
    #    python(abi) = MAJOR.MINOR
    # (Don't match against -config tools e.g. /usr/bin/python2.6-config)
    grep "/usr/bin/python.\..$" $tmpfile \
            | sed -e "s|.*/usr/bin/python\(.\..\)|python(abi) = \1|"

    pyver=`grep "/usr/lib[^/]*/python.\../.*" $tmpfile \
                | sed -e "s|.*/usr/lib[^/]*/python\(.\..\)/.*|\1|g" \
                | sort | uniq`

    # distutils-based
    grep "/usr/lib[^/]*/python[^/]*/.*\.egg-info$" $tmpfile \
            | while read egginfo; do
        [ -f "$egginfo" ] && pyprovides "$egginfo"
    done
    # setuptools-based
    grep "/usr/lib[^/]*/python[^/]*/.*\.egg-info/PKG-INFO$" $tmpfile \
            | while read egginfo; do
        [ -f "$egginfo" ] && pyprovides "$egginfo"
    done

    # Match python importable modules and provide as "python($MODULE_NAME)".
    # Versions are provided as "python($MODULE_NAME) = $MODULE_VERSION".
    grep "/usr/lib[^/]*/python[^/]*/site-packages/.*\.py$" $tmpfile \
            | while read abspyfile; do
        # Check for PEP-396 module version (if any):
        module_version=""
        version=`grep "^__version__" $abspyfile | cut -d " " -f 3`
        if [ -n "$version" ]; then
            version=${version:1:$((${#version} - 2))} # Transform '0.5' or "0.5" into 0.5...
            module_version="= $version"
        fi

        # Get the module 'path' relative to 'site-packages':
        module_relpath=`echo $abspyfile | grep -o "site-packages/.*\.py$" | cut -d "/" -f 2-`
        # Cut of '.py' ending and replace '/' with '.' to get a valid Python module name:
        module_name=`echo $module_relpath | rev | cut -d "." -f 2- | rev | sed "s|/|.|g"`
        # If a directory contains '__init__.py' it is a Python module too. Thus simply strip '__init__'
        # and use the directory name as 'module_name' (using bash-specific capture group reference):
        if [[ $module_name =~ (.*)\.__init__$ ]]; then
            module_name="${BASH_REMATCH[1]}"
        fi
        echo "python$pyver($module_name) $module_version"
    done

    exit 0
    ;;
-R|--requires)
    shift
    # Match buildroot paths of the form
    #    /PATH/OF/BUILDROOT/usr/lib/pythonMAJOR.MINOR/  and
    #    /PATH/OF/BUILDROOT/usr/lib64/pythonMAJOR.MINOR/
    # generating (uniqely) lines of the form:
    #    python(abi) = MAJOR.MINOR
    pyver=`grep "/usr/lib[^/]*/python.\../.*" $tmpfile \
                | sed -e "s|.*/usr/lib[^/]*/python\(.\..\)/.*|\1|g" \
                | sort | uniq`
    [ -z "$pyver" ] && exit 0
    echo "python(abi) = $pyver"
    # Optimisation: the rest of the script works with egg-infos
    grep -qs '\.egg-info' $tmpfile || exit 0
    # distutils-based
    grep "/usr/lib[^/]*/python[^/]*/.*\.egg-info$" $tmpfile \
            | while read egginfo; do
        [ -f "$egginfo" ] && pyrequires_distutils "$egginfo"
    done
    # setuptools-based
    grep "/usr/lib[^/]*/python[^/]*/.*\.egg-info/PKG-INFO$" $tmpfile \
            | while read egginfo; do
        [ -f "$egginfo" ] && pyrequires_distutils "$egginfo"
    done
    # Setuptools-specific requirements
    grep "/usr/lib[^/]*/python[^/]*/.*\.egg-info/requires.txt$" $tmpfile \
            | while read reqinfo; do
        [ -f "$reqinfo" ] && pyrequires_setuptools "$reqinfo"
    done
    #TODO: Python importable module requires
    exit 0
    ;;
esac

exit 0
