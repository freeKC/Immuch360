package app.alextran.immich.documenttree

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The reads of a file that can only be read from its start (a pipe), and which open file makes room for another */
class DocumentTreeReadsTest {
  private val mb = 1024L * 1024

  @Test
  fun readsOnForAnyJumpForwardHoweverFar() {
    assertEquals(
      SequentialReadPlan(reopen = false, skip = 0),
      SequentialReadPlan.of(position = 8 * mb, offset = 8 * mb),
    )
    assertEquals(
      SequentialReadPlan(reopen = false, skip = 40 * mb),
      SequentialReadPlan.of(position = 8 * mb, offset = 48 * mb),
    )
  }

  @Test
  fun opensAgainOnlyToGoBack() {
    assertEquals(SequentialReadPlan(reopen = true, skip = 0), SequentialReadPlan.of(position = 3000 * mb, offset = 0))
    assertEquals(SequentialReadPlan(reopen = true, skip = 64), SequentialReadPlan.of(position = 128, offset = 64))
  }

  @Test
  fun keepsThePipeAnUploadStreamsWhileTilesReadHeads() {
    val upload = OpenFileState("video", seekable = false, position = 1200 * mb)
    val firstHead = OpenFileState("photo1", seekable = false, position = 64 * 1024)

    // The upload's file is the least recently used, the head of a photo is cheap to read again
    val secondHead = OpenFileState("photo2", seekable = false, position = 0)
    assertEquals("photo1", OpenFilesPolicy.victim(listOf(upload, firstHead, secondHead), keep = "photo2"))
  }

  @Test
  fun closesTheLeastRecentlyUsedFileReadAtAPosition() {
    val files = listOf(
      OpenFileState("a", seekable = true, position = 0),
      OpenFileState("b", seekable = true, position = 0),
      OpenFileState("c", seekable = true, position = 0),
    )

    assertEquals("a", OpenFilesPolicy.victim(files, "c"))
  }

  @Test
  fun closesTheLeastRecentlyUsedWhenAllAreCostly() {
    val files = listOf(
      OpenFileState("a", seekable = false, position = 500 * mb),
      OpenFileState("b", seekable = false, position = 900 * mb),
      OpenFileState("c", seekable = false, position = 0),
    )

    assertEquals("a", OpenFilesPolicy.victim(files, "c"))
    assertNull(OpenFilesPolicy.victim(listOf(OpenFileState("c", false, 0)), "c"))
  }
}
