﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using TeslaSQL.Agents;
using Xunit;
using TeslaSQL.DataUtils;

namespace TeslaSQL.Tests.Agents {
    public class TestShardCoordinator : ShardCoordinator {
        public TestShardCoordinator() {
            this.sourceDataUtils = new TestDataUtils(TServer.RELAY);
        }
        [Fact]
        public void TestSchemasOutOfSync() {
            var ctb = new ChangeTrackingBatch(0, 0, 0, 0);
            var dbFieldLists = new List<Dictionary<string, List<TColumn>>>();
            var db1 = new List<TColumn>{
                new TColumn("a",false, null)
            };
            var db2 = new List<TColumn>{
                new TColumn("a",false, null)
            };
            var dict1 = new Dictionary<string, List<TColumn>>{
                {"db1", db1},
                {"db2",db2}
            };
            dbFieldLists.Add(dict1);
            shardDatabases = new List<string> { "db1", "db2" };
            Assert.False(SchemasOutOfSync(dbFieldLists));
            db1[0] = new TColumn("a", true, null);
            Assert.True(SchemasOutOfSync(dbFieldLists));
            db1.Clear();
            db1.Add(new TColumn("a", false, null));
            db1.Add(new TColumn("b", false, null));
            db2.Clear();
            db2.Add(new TColumn("b", false, null));
            db2.Add(new TColumn("a", false, null));
            Assert.False(SchemasOutOfSync(dbFieldLists));
        }

    }
}
