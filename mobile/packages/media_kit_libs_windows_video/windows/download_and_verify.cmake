# Immuch360: the download of the archives of this package (libmpv, ANGLE) at configure time, checked by SHA-256 rather
# than MD5, which no longer protects against a crafted file. See ../IMMUCH360-NOTE.md.
#
#   download_and_verify(URLS SHA256 LOCATION)
#
# An archive already at LOCATION with the SHA-256 given is kept; one with another SHA-256 is deleted. Otherwise the
# archive is downloaded next to LOCATION (LOCATION.part) and its SHA-256 checked after each attempt: only an archive
# with the right SHA-256 takes the name LOCATION, so that a download cut short or an error page of the server never
# stays behind as the archive. A failed attempt (an error of the transfer or another SHA-256) is reported as a warning
# and tried again after a pause, IMMUCH360_DOWNLOAD_ATTEMPTS attempts in all (4 by default), the pause starting at
# IMMUCH360_DOWNLOAD_PAUSE seconds (10 by default) and doubling after each attempt: a GitHub release that answers
# with an error once does not stop the build (it stopped the Windows job of the desktop workflow on 21 October 2026,
# "Integrity check failed"). Both may be CMake variables or environment variables. URLS may be a list (quoted, with
# semicolons): the attempts go through it in turn, so that a second source, when an archive has one, is tried after
# the first. After the last attempt the configure stops with every attempt and its reason.
function(download_and_verify urls sha256 locationForArchive)
  string(TOLOWER "${sha256}" sha256)

  # Check if the archive exists.
  if(EXISTS "${locationForArchive}")
    file(SHA256 "${locationForArchive}" ARCHIVE_SHA256)
    if(ARCHIVE_SHA256 STREQUAL sha256)
      return()
    endif()
    # If SHA-256 doesn't match, delete the archive to download again.
    file(REMOVE "${locationForArchive}")
    message(STATUS "SHA-256 mismatch. File deleted.")
  endif()

  set(attempts 4)
  if(DEFINED IMMUCH360_DOWNLOAD_ATTEMPTS)
    set(attempts "${IMMUCH360_DOWNLOAD_ATTEMPTS}")
  elseif(DEFINED ENV{IMMUCH360_DOWNLOAD_ATTEMPTS})
    set(attempts "$ENV{IMMUCH360_DOWNLOAD_ATTEMPTS}")
  endif()
  set(pause 10)
  if(DEFINED IMMUCH360_DOWNLOAD_PAUSE)
    set(pause "${IMMUCH360_DOWNLOAD_PAUSE}")
  elseif(DEFINED ENV{IMMUCH360_DOWNLOAD_PAUSE})
    set(pause "$ENV{IMMUCH360_DOWNLOAD_PAUSE}")
  endif()
  if(NOT attempts MATCHES "^[1-9][0-9]*$" OR NOT pause MATCHES "^[0-9]+$")
    message(FATAL_ERROR "IMMUCH360_DOWNLOAD_ATTEMPTS (${attempts}) must be a number above 0 and "
      "IMMUCH360_DOWNLOAD_PAUSE (${pause}) a number of seconds")
  endif()

  list(LENGTH urls url_count)
  set(part "${locationForArchive}.part")
  set(failures "")
  foreach(attempt RANGE 1 ${attempts})
    math(EXPR index "(${attempt} - 1) % ${url_count}")
    list(GET urls ${index} url)
    message(STATUS "Downloading archive from ${url} (attempt ${attempt} of ${attempts})...")
    file(REMOVE "${part}")
    file(DOWNLOAD "${url}" "${part}" STATUS status INACTIVITY_TIMEOUT 120)
    list(GET status 0 code)
    list(GET status 1 text)
    if(code EQUAL 0)
      file(SHA256 "${part}" ARCHIVE_SHA256)
      if(ARCHIVE_SHA256 STREQUAL sha256)
        file(RENAME "${part}" "${locationForArchive}")
        message(STATUS "Downloaded archive to ${locationForArchive}.")
        message(STATUS "${locationForArchive} Verification successful.")
        return()
      endif()
      file(SIZE "${part}" size)
      set(reason "SHA-256 ${ARCHIVE_SHA256} of ${size} bytes, ${sha256} expected")
    else()
      set(reason "download error ${code}, ${text}")
    endif()
    file(REMOVE "${part}")
    list(APPEND failures "attempt ${attempt}, ${url}: ${reason}")
    if(attempt LESS attempts)
      message(WARNING "Attempt ${attempt} of ${attempts} to download ${url} failed (${reason}): trying again in "
        "${pause} seconds.")
      if(pause GREATER 0)
        execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep "${pause}")
      endif()
      math(EXPR pause "${pause} * 2")
    endif()
  endforeach()

  list(JOIN failures "\n  " report)
  message(FATAL_ERROR "${locationForArchive} Integrity check failed after ${attempts} attempts, please try to "
    "re-build project again.\n  ${report}")
endfunction()
