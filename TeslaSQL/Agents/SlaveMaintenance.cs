﻿using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using TeslaSQL.DataUtils;

namespace TeslaSQL.Agents {
    /// <summary>
    /// This class is used for cleaning up old data on the slave (such as changetables for old batches)
    /// </summary>
    class SlaveMaintenance : Agent {
        private IDataUtils relayDataUtils { get { return sourceDataUtils; } }
        private IDataUtils slaveDataUtils { get { return destDataUtils; } }
        //base keyword invokes the base class's constructor
        public SlaveMaintenance(IDataUtils relayDataUtils, IDataUtils slaveDataUtils, Logger logger)
            : base(relayDataUtils, slaveDataUtils, logger) {
        }

        public override void ValidateConfig() {
            Config.ValidateRequiredHost(Config.slave);
            if (Config.slaveType == null) {
                throw new Exception("SlaveMaintenance agent requires a valid SQL flavor for slave");
            }
        }
        public override void Run() {
            var chopDate = DateTime.Now - new TimeSpan(Config.changeRetentionHours, 0, 0);
            var rowChopDate = DateTime.Now - new TimeSpan(Config.batchRecordRetentionDays, 0, 0, 0);
            IEnumerable<long> ctids = relayDataUtils.GetOldCTIDsSlave(Config.relayDB, chopDate, Config.slave);
            var tables = slaveDataUtils.GetTables(Config.slaveCTDB);
            logger.Log("Deleting {" + string.Join(",", ctids) + "} from { " + string.Join(",", tables.Select(t => t.name)) + "}", LogLevel.Debug);
            MaintenanceHelper.DeleteOldTables(ctids, tables, slaveDataUtils);
        }
    }
}
